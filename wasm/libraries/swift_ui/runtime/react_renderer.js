// The web half of the ReactRenderer (the component-system renderer
// bound by isoStart when the page asks for "react").
//
// Interprets the runtime's serialized view tree (docs/renderer_layers.md) as
// React elements built from web-native components: flex layout, real inputs
// (<input type=search|date|checkbox>, <select>), a header nav bar, a bottom
// tab bar, and modal presentations. Interactive nodes report back through
// `sendEvent(id, value)` (which feeds Runtime.hostViewEvent). React owns
// layout and reconciliation — the runtime never computes frames or emits
// draw commands under this binding.
//
// Uses the React 18 UMD globals (window.React / window.ReactDOM), served
// from the hermetic @react_umd repositories next to this bundle.

import { resolveImageSource } from "./raster.js";
import { SYMBOLS } from "./symbols.js";
import { storeFiles } from "./imported_files.js";

/// An SF Symbol drawn from the portable table as an inline SVG sized to
/// the text it stands in (an `Image(systemName:)` is a text node carrying
/// `params.symbol`); unknown names keep the guest's fallback glyph.
/** A shape node's `path` param (Shapes.swift: `M x y`, `L x y`, `Z`,
 *  `R x y w h`, `Q x y w h r`, `E x y w h`, in the unit square) as SVG
 *  path data. A rounded rect's corners and an ellipse are arcs. */
function svgPathData(text) {
  const t = text.split(" ");
  const out = [];
  for (let i = 0; i < t.length;) {
    const op = t[i++];
    const n = () => Number(t[i++]);
    if (op === "M") out.push(`M ${n()} ${n()}`);
    else if (op === "L") out.push(`L ${n()} ${n()}`);
    else if (op === "Z") out.push("Z");
    else if (op === "R") { const x = n(), y = n(), w = n(), h = n(); out.push(`M ${x} ${y} h ${w} v ${h} h ${-w} Z`); }
    else if (op === "Q") {
      const x = n(), y = n(), w = n(), h = n(), r = Math.min(n(), w / 2, h / 2);
      out.push(`M ${x + r} ${y} h ${w - 2 * r} a ${r} ${r} 0 0 1 ${r} ${r} v ${h - 2 * r} a ${r} ${r} 0 0 1 ${-r} ${r} h ${-(w - 2 * r)} a ${r} ${r} 0 0 1 ${-r} ${-r} v ${-(h - 2 * r)} a ${r} ${r} 0 0 1 ${r} ${-r} Z`);
    } else if (op === "E") {
      const x = n(), y = n(), w = n(), h = n(), rx = w / 2, ry = h / 2;
      out.push(`M ${x} ${y + ry} a ${rx} ${ry} 0 1 0 ${w} 0 a ${rx} ${ry} 0 1 0 ${-w} 0 Z`);
    } else break;
  }
  return out.join(" ");
}

let symbolMasks = 0;
function symbolSVG(h, name, size, color, weight, extraStyle, secondary) {
  const entry = SYMBOLS[name];
  if (!entry) return null;
  const px = Math.round((Number(size) || 17) * 1.15);
  const bold = Number(weight) >= 600;
  // A filled badge's glyph is cut out of it, what is behind showing through
  // (SF's `.fill`: a white play.circle.fill over a tile shows the tile in
  // its triangle); a closed glyph (the triangle) is cut out whole. Each
  // drawing's mask has an id of its own: a shared one would resolve to the
  // first in the page, which a hidden element's mask does not draw.
  const cut = entry.inner && !secondary ? `iso-cut-${++symbolMasks}` : null;
  const closedGlyph = !!entry.inner && /[zZ]\s*$/.test(entry.inner);
  return h("svg", {
    viewBox: "0 0 24 24", width: px, height: px, "aria-hidden": "true",
    // With a secondary style (`.foregroundStyle(_:_:)`) a filled badge takes
    // it, and its glyph the primary colour.
    fill: entry.fill ? (secondary && entry.inner ? secondary : "currentColor") : "none", stroke: secondary && entry.inner ? secondary : "currentColor",
    strokeWidth: entry.fill ? 1.5 : (bold ? 2.4 : 2), strokeLinecap: "round", strokeLinejoin: "round",
    style: { display: "inline-block", verticalAlign: "-0.2em", color, flexShrink: 0, ...extraStyle },
  }, cut ? h("defs", { key: "m" }, h("mask", { id: cut, maskUnits: "userSpaceOnUse", x: -2, y: -2, width: 28, height: 28 },
       h("rect", { x: -2, y: -2, width: 28, height: 28, fill: "#fff" }),
       h("path", { d: entry.inner, fill: closedGlyph ? "#000" : "none", stroke: "#000", strokeWidth: 2.2 }))) : null,
     h("path", { key: "d", d: entry.d, mask: cut ? `url(#${cut})` : undefined }),
     // With a secondary style, the glyph in the primary.
     entry.inner && !cut ? h("path", { key: "i", d: entry.inner, fill: closedGlyph ? "currentColor" : "none", stroke: "currentColor", strokeWidth: 2.2 }) : null);
}

export function createReactTreeRenderer({ container, sendEvent, sendKey = (id, value) => { sendEvent(id, value); return false; }, assetBase = "assets/", mapSurface = null, metalViews = null, documentScroll = false }) {
  const R = window.React;
  const SYSTEM_FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif";
  const MONO_FONT = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace";
  const h = R.createElement;
  const root = window.ReactDOM.createRoot(container);

  // `.keyboardShortcut`: a key press finds the view marked with it on the
  // page now and presses the button in it (⌘ is Ctrl off the Mac).
  if (!window.__isoShortcuts) {
    window.__isoShortcuts = true;
    const mac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
    document.addEventListener("keydown", (e) => {
      const names = { Enter: "enter", Escape: "escape", Tab: "tab", " ": "space", Backspace: "backspace",
        ArrowUp: "arrowup", ArrowDown: "arrowdown", ArrowLeft: "arrowleft", ArrowRight: "arrowright" };
      const parts = [];
      if (mac ? e.metaKey : e.ctrlKey) parts.push("cmd");
      if (mac && e.ctrlKey) parts.push("ctrl");
      if (e.altKey) parts.push("alt");
      if (e.shiftKey) parts.push("shift");
      parts.push(names[e.key] || (e.key || "").toLowerCase());
      const marked = document.querySelectorAll(`[data-shortcut="${CSS.escape(parts.join("+"))}"]`);
      const view = marked[marked.length - 1];
      if (!view) return;
      const button = view.matches("[data-tap]") ? view : view.querySelector("[data-tap]");
      if (!button) return;
      e.preventDefault();
      button.click();
    }, true);
  }

  if (!document.getElementById("iso-react-style")) {
    const style = document.createElement("style");
    style.id = "iso-react-style";
    style.textContent =
      "@keyframes iso-spin{to{transform:rotate(1turn)}}" +
      // The spinner in the text's own colour, as iOS draws it in the
      // secondary label's: a faint track and a stronger head, so it reads on
      // a dark page and turns white on a selected row (a fixed mid-grey was
      // all but invisible on both). The fixed grey stays for browsers without
      // color-mix.
      ".iso-spinner{width:22px;height:22px;border-radius:50%;flex:none;" +
      "border:2.5px solid rgba(120,120,128,0.3);border-top-color:rgba(120,120,128,0.9);" +
      "border-color:color-mix(in srgb,currentColor 22%,transparent);" +
      "border-top-color:color-mix(in srgb,currentColor 85%,transparent);" +
      "animation:iso-spin 0.8s linear infinite}" +
      // A chat's rows (a bottom-anchored list) are laid out for real, off
      // screen too: sized by the 44pt estimate, a thread opening at its end
      // pinned against the estimates, then its last rows took their real
      // heights and the text under the reader moved.
      ".iso-anchor-bottom [data-iso-cell]{content-visibility:visible !important}" +
      ".iso-tap{transition:background-color 0.12s}" +
      // An upper ZStack layer passes the pointer through its empty space
      // (stacks, spacers, frames), as SwiftUI hit-tests only content: what
      // can be hit inside it (data-hit) takes it back, unless something
      // above it has `.allowsHitTesting(false)`.
      ".iso-pass [data-hit]{pointer-events:auto}" +
      ".iso-pass [data-nohit],.iso-pass [data-nohit] *{pointer-events:none}" +
      ".iso-bar-item:not(:disabled):hover{background:rgba(120,120,128,0.16) !important}" +
      ".iso-bar-item:not(:disabled):active{background:rgba(120,120,128,0.26) !important}" +
      ".iso-tap:active{background-color:rgba(120,120,128,0.18) !important}" +
      ".iso-switch{appearance:none;-webkit-appearance:none;width:44px;height:26px;flex:none;" +
      "border-radius:13px;background:rgba(120,120,128,0.35);position:relative;outline:none;" +
      "cursor:pointer;transition:background 0.15s;border:none;margin:0}" +
      ".iso-switch:checked{background:#34c759}" +
      ".iso-switch::after{content:'';position:absolute;left:2px;top:2px;width:22px;height:22px;" +
      "border-radius:50%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,0.3);transition:left 0.15s}" +
      ".iso-switch:checked::after{left:20px}" +
      // iOS inset-grouped list: rows in rounded groups on the grouped
      // background, separators inset from the leading edge, the last row of
      // a group (before a header, or at the end) closing it. The groups are
      // rounded as iOS 26 rounds them: 26px, the circle that fits the
      // simulator's corner (10px was the radius before Liquid Glass); a
      // one-row group comes out a capsule, as there.
      ".iso-ig{padding:12px 16px 24px;box-sizing:border-box;display:flex;flex-direction:column;align-self:stretch;width:100%}" +
      ".iso-ig-row{background:var(--iso-cell-bg,#fff);position:relative}" +
      // iOS 26's separator: inset 16pt from both edges, lighter than the
      // older hairline.
      ".iso-ig-row::after{content:'';position:absolute;left:var(--iso-sep-l,16px);right:var(--iso-sep-r,16px);bottom:0;height:1px;background:var(--iso-ig-sep)}" +
      ".iso-ig-row:first-child,.iso-ig-header+.iso-ig-row,.iso-ig-footer+.iso-ig-row{border-top-left-radius:26px;border-top-right-radius:26px}" +
      ".iso-ig-row:last-child,.iso-ig-row:has(+ .iso-ig-header),.iso-ig-row:has(+ .iso-ig-footer){border-bottom-left-radius:26px;border-bottom-right-radius:26px}" +
      ".iso-ig-row:last-child::after,.iso-ig-row:has(+ .iso-ig-header)::after,.iso-ig-row:has(+ .iso-ig-footer)::after{display:none}" +
      ".iso-ig-selected,.iso-ig-selected *{color:#fff!important}" +
      ".iso-ig-selected::after,.iso-ig-row:has(+ .iso-ig-selected)::after{display:none}" +
      // Headers as iOS 26 draws them: sentence case, secondary, a step
      // smaller than the rows.
      ".iso-ig-header{padding:22px 16px 8px;font-size:15px;color:rgba(120,120,128,0.95)}" +
      // iOS 26: the first header close under the title, 36pt between
      // sections without one.
      ".iso-ig-header:first-child{padding-top:0!important}" +
      ".iso-ig-gap{padding:0!important;height:36px;min-height:36px}" +
      // A section's footer, under its group in line with its rows' text.
      ".iso-ig-footer{padding:7px 16px 0}" +
      // A footer's section followed by one without a header: the gap is
      // the footer's and the space after it.
      ".iso-ig-footer+.iso-ig-gap{height:28px;min-height:28px}" +
      ".iso-plain-gap{padding:0!important;height:0;min-height:0!important;overflow:hidden}" +
      // Sheet content spans the panel; its own stacks keep their alignment.
      ".iso-sheet-body>*{align-self:stretch}" +
      ".iso-principal button{color:inherit}" +
      // macOS sidebar rows and headers.
      // The page itself never scrolls or rubber-bands (a phone browser's
      // overscroll dragged the bars with the document); only our scroll
      // containers scroll, and they do not chain to the page at their ends.
      // A document-scrolled page is the exception: the page is what scrolls.
      // (boot.js puts `iso-document` on <html> while a phone-width page
      // scrolls as a document.)
      // The page scrolls down its length only: nothing pans it sideways,
      // not even to rubber-band (a phone browser pans a scrollable page on
      // both axes under a finger). Clipped rather than hidden, so the page
      // stays the scroll that sticky chrome sticks to; scrolls inside it
      // that run sideways are their own and keep their pan.
      "html.iso-document{height:100%;overflow-x:clip;overscroll-behavior-x:none;touch-action:pan-y pinch-zoom}" +
      "html.iso-document body{margin:0;min-height:100%;overflow-x:clip;overscroll-behavior-x:none;touch-action:pan-y pinch-zoom}" +
      // Everything around the document-scrolled screen's scroll takes its
      // content's height (at least the viewport's), so the page is as long
      // as the screen's content and sticky chrome in it travels the page.
      // (Stretched, too: a content-sized root is otherwise centered in the
      // page, and a short screen would sit in the middle of it.)
      "[data-iso-document] :has([data-document-scroll]){flex:1 0 auto!important;min-height:auto!important;height:auto!important;max-height:none!important;place-self:stretch!important}" +
      "html:not(.iso-document){overscroll-behavior:none;overflow:hidden;height:100%}" +
      "html:not(.iso-document) body{overscroll-behavior:none;overflow:hidden;position:fixed;inset:0;width:100%;height:100dvh;margin:0}" +
      "[data-edge-scroll],.iso-sheet-body,[data-iso-scroll]{overscroll-behavior:contain}" +
      ".iso-no-sep::after{display:none!important}" +
      ".iso-no-scrollbar::-webkit-scrollbar{display:none}" +
      // A horizontal scroll offers its content unlimited width, as
      // SwiftUI's does: its content keeps its own width (and starts at the
      // leading edge) instead of shrinking to the scroll's and centering
      // what overflows, half of it out of reach.
      "[data-iso-hscroll]>*{flex-shrink:0!important;min-width:max-content!important}" +
      // The Mac's push button (a Form's button at regular width): a
      // rounded fill, its label in the text colour.
      // Dark by the system's setting unless the app chose light, or by
      // the app's choice.
      ".iso-mac-push{background:rgba(0,0,0,0.06);box-shadow:inset 0 0 0 0.5px rgba(0,0,0,0.18)}" +
      ".iso-mac-push,.iso-mac-push *{color:rgba(0,0,0,0.85)!important}" +
      "@media (prefers-color-scheme: dark){html:not([data-theme=light]) .iso-mac-push{background:rgba(255,255,255,0.13);box-shadow:inset 0 0.5px 0 rgba(255,255,255,0.12)}" +
      "html:not([data-theme=light]) .iso-mac-push,html:not([data-theme=light]) .iso-mac-push *{color:rgba(255,255,255,0.88)!important}}" +
      "html[data-theme=dark] .iso-mac-push{background:rgba(255,255,255,0.13);box-shadow:inset 0 0.5px 0 rgba(255,255,255,0.12)}" +
      "html[data-theme=dark] .iso-mac-push,html[data-theme=dark] .iso-mac-push *{color:rgba(255,255,255,0.88)!important}" +
      // Disabled, its label dimmed as the Mac dims it.
      ".iso-mac-push[data-disabled],.iso-mac-push[data-disabled] *{color:rgba(0,0,0,0.25)!important}" +
      "@media (prefers-color-scheme: dark){html:not([data-theme=light]) .iso-mac-push[data-disabled],html:not([data-theme=light]) .iso-mac-push[data-disabled] *{color:rgba(255,255,255,0.25)!important}}" +
      "html[data-theme=dark] .iso-mac-push[data-disabled],html[data-theme=dark] .iso-mac-push[data-disabled] *{color:rgba(255,255,255,0.25)!important}" +
      ".iso-mac-form-header,.iso-mac-form-header *{font-size:13px!important;line-height:16px!important;font-weight:600!important;color:inherit!important}" +
      ".iso-ios-form-header{padding-top:4px;padding-bottom:4px}" +
      ".iso-ios-form-header *{font-size:17px!important;line-height:22px!important;font-weight:600!important}" +
      ".iso-form-sep>*{background:var(--iso-ig-sep)!important}" +
      ".iso-ios-list-label{gap:17px!important}" +
      ".iso-ios-list-label>:first-child{width:24px;min-width:24px;justify-content:center;font-size:17px}" +
      ".iso-ios-list-label-tint>:first-child,.iso-ios-list-label-tint>:first-child *{color:var(--iso-tint,#007aff)!important}" +
      ".iso-mac-form-footer *{font-size:12px!important;line-height:16px!important}" +
      // A grouped cell's fill, for a list outside a grouped container too
      // (the fallback used to be white, which flashed in dark mode).
      ":root{--iso-cell-bg:#fff;--iso-separator:rgba(60,60,67,0.29);--iso-ig-sep:rgba(60,60,67,0.12);--iso-mac-selection:#0064e1}" +
      "@media (prefers-color-scheme: dark){:root{--iso-mac-selection:#0058d0}}" +
      "html[data-theme=dark]{--iso-mac-selection:#0058d0}html[data-theme=light]{--iso-mac-selection:#0064e1}" +
      "@media (prefers-color-scheme: dark){:root{--iso-cell-bg:#1c1c1e;--iso-separator:rgba(84,84,88,0.65);--iso-ig-sep:rgba(84,84,88,0.6)}}" +
      "@media (min-width: 700px){:root{--iso-ig-sep:rgba(60,60,67,0.18)}}" +
      "@media (min-width: 700px) and (prefers-color-scheme: dark){:root{--iso-ig-sep:rgba(255,255,255,0.1)}}" +
      "@media (min-width: 700px) and (prefers-color-scheme: dark){:root{--iso-cell-bg:#2e2e30}}" +
      ".iso-plain-row{position:relative}" +
      ".iso-plain-row::after{content:'';position:absolute;left:16px;right:0;bottom:0;height:1px;background:rgba(120,120,128,0.3)}" +
      ".iso-plain-row:last-child::after{display:none}" +
      // An iPhone's plain list stops its lines short of the trailing edge.
      "@media (max-width: 699px){.iso-plain-row::after{right:16px}}" +
      // The page is the app's ground: black or white, the safe areas too.
      "body{background:#fff;color-scheme:light dark}" +
      "@media (prefers-color-scheme: dark){body{background:#000}}" +
      // Two columns wide, the Mac's dark window grey rather than the
      // iPhone's black (MAC_DARK_PAGE).
      "@media (min-width: 700px) and (prefers-color-scheme: dark){body{background:#232325}}" +
      ".iso-sb-row{transition:background-color 0.1s}" +
      ".iso-sb-row:hover:not(.iso-sb-selected){background:rgba(120,120,128,0.12)}" +
      ".iso-sb-selected,.iso-sb-selected *{color:#fff !important}" +
      ".iso-sb-selected svg{color:#fff !important}" +
      ".iso-sb-header{padding:14px 20px 4px;font-size:11px;font-weight:600;color:rgba(120,120,128,0.9)}" +
      // Thin, overlay-like scrollbars everywhere (the always-on dark
      // scrollbar looked like a control).
      "*{scrollbar-width:thin;scrollbar-color:rgba(120,120,128,0.45) transparent}";
    document.head.appendChild(style);
  }

  // A text's typeface: a named one (`Font.custom`, the system's after it),
  // the design's (`.serif`, `.rounded`, `.monospaced`), else the system's.
  function fontFamilyCSS(p) {
    p = p || {};
    if (p.family) return `"${p.family.replace(/"/g, "")}", ${SYSTEM_FONT}`;
    if (p.mono === "1") return MONO_FONT;
    if (p.design === "serif") return `ui-serif, "New York", Georgia, serif`;
    if (p.design === "rounded") return `ui-rounded, "SF Pro Rounded", ${SYSTEM_FONT}`;
    return SYSTEM_FONT;
  }

  // A list row's padding: `.listRowInsets` ("top,leading,bottom,trailing",
  // "-" for a side left to the list), each side the list's `d` otherwise.
  const rowInsetValues = (p, d) => {
    const parts = ((p || {}).rowInsets || "").split(",");
    return parts.length === 4
      ? parts.map((x, i) => (x === "-" || x === "" || !isFinite(Number(x)) ? d[i] : Number(x)))
      : d;
  };
  const rowPadding = (p, d) => {
    const v = rowInsetValues(p, d);
    return `${v[0]}px ${v[3]}px ${v[2]}px ${v[1]}px`;
  };

  const rgba = (c) =>
    c ? `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${c[3]})` : undefined;

  const alignCSS = { leading: "flex-start", center: "center", trailing: "flex-end", top: "flex-start", bottom: "flex-end" };

  // The frost of materials and bar buttons.
  const MATERIAL_BLUR = "blur(14px)";

  function gradientCSS(n) {
    if (!n.gradient) return undefined;
    try {
      const g = JSON.parse(n.gradient);
      const colors = (g.stops || [])
        .map((stop) => `${rgba(stop.c)} ${Math.round((stop.l || 0) * 100)}%`)
        .join(",");
      if (!colors) return undefined;
      if (g.kind === "radial") return `radial-gradient(circle, ${colors})`;
      if (g.kind === "angular") return `conic-gradient(${colors})`;
      if (g.kind === "solid") return rgba((g.stops[0] || {}).c);
      const angle = g.p0 && g.p1
        ? Math.atan2(g.p1[1] - g.p0[1], g.p1[0] - g.p0[0]) * 180 / Math.PI + 90
        : 180;
      return `linear-gradient(${angle}deg, ${colors})`;
    } catch (_) {
      return undefined;
    }
  }

  function baseStyle(n) {
    const s = { boxSizing: "border-box" };
    if (n.padding) {
      s.paddingTop = n.padding[0];
      s.paddingLeft = n.padding[1];
      s.paddingBottom = n.padding[2];
      s.paddingRight = n.padding[3];
    }
    // A fixed frame never shrinks under row or column pressure (SwiftUI
    // gives a `.frame(width:)` its width; the flexible siblings give way).
    if (n.width != null) { s.width = n.width; s.minWidth = n.width; s.flexShrink = 0; }
    if (n.height != null) { s.height = n.height; s.minHeight = n.height; }
    if (n.bg) s.background = namedFillCSS(n.params && n.params.bgName, n.bg);
    const gradient = gradientCSS(n);
    if (gradient) s.background = gradient;
    // cornerRadius has CLIP semantics (SwiftUI clips to the rounded rect);
    // without overflow:hidden an oversized child (a fill image) pokes past
    // the rounded corners and the frame itself.
    if (n.radius) { s.borderRadius = n.radius; s.overflow = "hidden"; }
    if (n.opacity != null) s.opacity = n.opacity;
    if (n.shadow) {
      // On a view with a fill, its box's shadow; on what is drawn alone (a
      // symbol, words) the shape's, as SwiftUI shades what is drawn (a box
      // around a symbol's glyph cast a square). drop-shadow's third length
      // is the deviation, half box-shadow's blur.
      if (n.bg || gradient) s.boxShadow = `${n.shadow.x}px ${n.shadow.y}px ${n.shadow.radius * 2}px ${rgba(n.shadow.color)}`;
      else s.filter = `drop-shadow(${n.shadow.x}px ${n.shadow.y}px ${n.shadow.radius}px ${rgba(n.shadow.color)})`;
    }
    // A `Material` / `.glassEffect` fill: its tint over a blur of what lies
    // behind, with a hairline — the bar buttons' material.
    if (n.gradient && n.gradient.indexOf('"material"') >= 0) {
      const dark = pageDark();
      s.backdropFilter = MATERIAL_BLUR;
      s.WebkitBackdropFilter = MATERIAL_BLUR;
      const hairline = `inset 0 0 0 1px ${dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.08)"}`;
      s.boxShadow = [hairline, s.boxShadow || (dark ? "0 1px 6px rgba(0,0,0,0.25)" : "0 1px 6px rgba(0,0,0,0.08)")].join(",");
    }
    if (n.tap) s.cursor = "pointer";
    // Visual transforms (.offset / .scaleEffect): per-frame values from the
    // guest's animator, applied as a CSS transform about the center.
    if (n.offsetX != null || n.offsetY != null || n.scale != null) {
      const parts = [];
      if (n.offsetX != null || n.offsetY != null) parts.push(`translate(${n.offsetX || 0}px, ${n.offsetY || 0}px)`);
      if (n.scale != null) parts.push(`scale(${n.scale})`);
      s.transform = parts.join(" ");
    }
    if (n.drag) s.touchAction = "none";
    return s;
  }

  // `.accessibilityLabel/Hint/Value/Identifier/Hidden` → ARIA / test ids.
  function accessibility(n, props) {
    const p = n.params;
    if (!p) return props;
    if (p.a11yLabel !== undefined) props["aria-label"] = p.a11yLabel;
    if (p.a11yHint !== undefined) props["aria-description"] = p.a11yHint;
    if (p.a11yValue !== undefined) props["aria-valuetext"] = p.a11yValue;
    if (p.a11yId !== undefined) props["data-testid"] = p.a11yId;
    if (p.a11yHidden === "1") props["aria-hidden"] = "true";
    // `.accessibilityElement(children:)`: one element read as a whole
    // (`.combine`: a group; `.ignore`: a leaf with its own label).
    if (p.a11yChildren === "combine" || p.a11yChildren === "contain") props.role = props.role || "group";
    if (p.a11yChildren === "ignore" && p.a11yLabel !== undefined) props.role = props.role || "img";
    // `.id(_:)`: what a ScrollViewProxy's scrollTo finds.
    if (p.vid !== undefined) props["data-vid"] = p.vid;
    return props;
  }

  // Node kinds that take input on their own, without a tap/drag/edit field.
  const LAYER_INPUT_KINDS = new Set([
    "scroll", "webview", "video", "toggle", "textField", "slider", "search", "picker", "menu", "map", "metal",
    "datepicker", "codeeditor", "tabbar", "navbar", "presentation", "hostView", "surface",
  ]);

  // What SwiftUI hit-tests: content (text, images, shapes, controls, a
  // filled background) and anything with a gesture or an input of its own;
  // not a stack's, a spacer's or a frame's empty space. Upper ZStack layers
  // pass the pointer through the rest (`.iso-pass`).
  const HIT_KINDS = new Set(["text", "image", "shape", "gradient", "divider", "progress"]);
  function hittable(n) {
    if (n.tap || n.drag || n.edit) return true;
    if (HIT_KINDS.has(n.k) || LAYER_INPUT_KINDS.has(n.k)) return true;
    if (n.gradient) return true;
    if (n.bg) return !(Array.isArray(n.bg) && n.bg.length === 4 && n.bg[3] === 0);
    return false;
  }

  function interactive(n, props) {
    accessibility(n, props);
    const params = n.params || {};
    if (params.tint) {
      // `.tint`: buttons/links in the subtree read the accent from this var.
      props.style = { ...(props.style || {}), "--iso-tint": params.tint, accentColor: params.tint };
    }
    if (params.clip === "1") props.style = { ...(props.style || {}), overflow: "hidden" };
    // `.zIndex`, `.allowsHitTesting(false)`, `.blur`, `.help`, `.onHover`,
    // `.keyboardShortcut` (found by the key handler below).
    if (params.z) props.style = { ...(props.style || {}), zIndex: Number(params.z), position: (props.style || {}).position || "relative" };
    if (params.nohit === "1") {
      props.style = { ...(props.style || {}), pointerEvents: "none" };
      props["data-nohit"] = "";
    } else if (hittable(n)) {
      props["data-hit"] = "";
    }
    if (params.blur) props.style = { ...(props.style || {}), filter: `blur(${Number(params.blur)}px) ${(props.style || {}).filter || ""}`.trim() };
    if (params.help) props.title = params.help;
    if (params.hover) {
      const id = params.hover;
      props.onMouseEnter = () => sendEvent(id, "1");
      props.onMouseLeave = () => sendEvent(id, "0");
    }
    if (params.shortcut) props["data-shortcut"] = params.shortcut;
    // A Form's parts in the platform's metrics. Two columns wide, the Mac's
    // grouped form: a 13pt semibold header in the label colour, a 12pt
    // footer. One column wide, iOS 26's: 52pt rows, 26pt corners, a 17pt
    // semibold header, separators inset from both edges.
    if (params.form) {
      const desk = isDesktop();
      const role = params.form;
      if (desk && (role === "header" || role === "footer")) {
        props.className = ((props.className || "") + " iso-mac-form-" + role).trim();
      } else if (!desk && role === "header") {
        props.className = ((props.className || "") + " iso-ios-form-header").trim();
      } else if (!desk && role === "row") {
        props.style = { ...(props.style || {}), minHeight: 52, paddingTop: 13, paddingBottom: 13 };
      } else if (!desk && role === "card") {
        props.style = { ...(props.style || {}), borderRadius: 26 };
      }
      if (role === "separator") props.className = ((props.className || "") + " iso-form-sep").trim();
    }
    // A Label in an iPhone's inset-grouped row: its icon in a column of its
    // own and the title on the row's text line, the icon in the accent
    // colour.
    if (params.label === "1" && inListCell && !isDesktop() && (currentListStyle === "insetGrouped" || currentListStyle === "plain")) {
      // (Only an icon whose colour is left to its container: a style set
      // around the label, a destructive button's red, keep theirs.)
      const icon = (n.ch || [])[0];
      const plain = !!icon && ((icon.params || {}).autoColor === "1");
      props.className = ((props.className || "") + " iso-ios-list-label" + (plain ? " iso-ios-list-label-tint" : "")).trim();
    }
    // `.textSelection`: said outright, so a container that turns selection
    // off (a context menu's long press) doesn't turn it off here, and an
    // inner one overrides an outer one. (Safari still wants the prefix.)
    if (params.select) {
      const value = params.select === "1" ? "text" : "none";
      props.style = { ...(props.style || {}), userSelect: value, WebkitUserSelect: value };
    }
    if (params.fixed) {
      // `.fixedSize`: the box takes its content's ideal size on the fixed
      // axes, whatever room the parent offers, and never shrinks.
      const fixed = { flexShrink: 0 };
      if (params.fixed.includes("h")) { fixed.width = "max-content"; fixed.maxWidth = "none"; }
      if (params.fixed.includes("v")) { fixed.height = "max-content"; fixed.maxHeight = "none"; }
      props.style = { ...(props.style || {}), ...fixed };
    }
    if (params.aspect) props.style = { ...(props.style || {}), aspectRatio: String(params.aspect) };
    if (params.interp === "none") props.style = { ...(props.style || {}), imageRendering: "pixelated" };
    if (params.posX !== undefined && params.posY !== undefined) {
      // `.position`: the child's center at (x, y) in the parent (the parent
      // is positioned; see the container rule in render()).
      props.style = {
        ...(props.style || {}), position: "absolute", left: Number(params.posX), top: Number(params.posY),
        transform: ((props.style || {}).transform ? (props.style || {}).transform + " " : "") + "translate(-50%, -50%)",
        width: "auto", height: "auto", flex: "none",
      };
    }
    const magnify = (n.params || {}).magnify;
    if (n.drag || magnify) {
      // A guest `.gesture`: pointer capture; the drag reports the pointers'
      // travel ("changed:x,y" / "ended:x,y") and a pinch the spread of two
      // fingers since it began ("changed:m" / "ended:m"). A trackpad pinch
      // arrives as ctrl+wheel, and ends once it pauses.
      if (magnify) props.style = { ...(props.style || {}), touchAction: "none" };
      const state = (el) => (el.__isoGesture ||= { points: new Map(), start: null, spread: null, zoom: 1, moved: { x: 0, y: 0 } });
      const centroid = (points) => {
        let x = 0, y = 0;
        for (const p of points.values()) { x += p.x; y += p.y; }
        return { x: x / points.size, y: y / points.size };
      };
      const spread = (points) => {
        const [a, b] = [...points.values()];
        return Math.hypot(a.x - b.x, a.y - b.y);
      };
      // A drag begins once the pointer has moved `minimumDistance` (SwiftUI's
      // rule, default 10): before that the press is still a tap for the views
      // inside, so the pointer is captured only when the drag (or a pinch)
      // begins — capturing at once would hand the click to this element and
      // the inner `.onTapGesture` would never see it.
      const dragMin = Number((n.params || {}).dragMin ?? 10);
      props.onPointerDown = (e) => {
        const st = state(e.currentTarget);
        st.points.set(e.pointerId, { x: e.clientX, y: e.clientY });
        if (!st.down) st.down = { x: e.clientX, y: e.clientY };
        const c = centroid(st.points);
        // A finger joining or leaving restarts the reference points, so the
        // translation carries on from where it was.
        st.start = { x: c.x - st.moved.x, y: c.y - st.moved.y };
        if (st.points.size === 2) st.spread = { base: spread(st.points), zoom: st.zoom };
      };
      props.onPointerMove = (e) => {
        const st = e.currentTarget.__isoGesture;
        if (!st || !st.points.has(e.pointerId)) return;
        st.points.set(e.pointerId, { x: e.clientX, y: e.clientY });
        if (!st.engaged) {
          const far = st.down && Math.hypot(e.clientX - st.down.x, e.clientY - st.down.y) >= dragMin;
          if (!far && st.points.size < 2) return;
          st.engaged = true;
          for (const id of st.points.keys()) { try { e.currentTarget.setPointerCapture(id); } catch (_) {} }
        }
        const c = centroid(st.points);
        st.moved = { x: c.x - st.start.x, y: c.y - st.start.y };
        if (n.drag) sendEvent(n.drag, `changed:${st.moved.x},${st.moved.y}`);
        if (magnify && st.points.size === 2 && st.spread && st.spread.base > 0) {
          st.zoom = st.spread.zoom * spread(st.points) / st.spread.base;
          sendEvent(magnify, `changed:${st.zoom}`);
        }
      };
      const end = (e) => {
        const st = e.currentTarget.__isoGesture;
        if (!st || !st.points.has(e.pointerId)) return;
        st.points.delete(e.pointerId);
        if (st.points.size > 0) {
          const c = centroid(st.points);
          st.start = { x: c.x - st.moved.x, y: c.y - st.moved.y };
          st.spread = null;
          return;
        }
        // A press that never moved far enough was a tap, not a drag.
        if (st.engaged) {
          if (n.drag) sendEvent(n.drag, `ended:${st.moved.x},${st.moved.y}`);
          if (magnify) sendEvent(magnify, `ended:${st.zoom}`);
        }
        e.currentTarget.__isoGesture = null;
      };
      props.onPointerUp = end;
      props.onPointerCancel = end;
      if (magnify) {
        props.onWheel = (e) => {
          if (!e.ctrlKey) return;
          e.preventDefault();
          const el = e.currentTarget;
          const st = state(el);
          st.zoom *= Math.exp(-e.deltaY / 100);
          sendEvent(magnify, `changed:${st.zoom}`);
          clearTimeout(st.wheelEnd);
          st.wheelEnd = setTimeout(() => { sendEvent(magnify, `ended:${st.zoom}`); el.__isoGesture = null; }, 150);
        };
      }
    }
    // `.dropDestination`: files dragged over and dropped on the view.
    const drop = (n.params || {}).drop;
    if (drop) {
      const carriesFiles = (e) => Array.from((e.dataTransfer && e.dataTransfer.types) || []).includes("Files");
      props.onDragOver = (e) => { if (carriesFiles(e)) { e.preventDefault(); e.dataTransfer.dropEffect = "copy"; } };
      props.onDragEnter = (e) => { if (carriesFiles(e)) sendEvent(drop, "over:1"); };
      props.onDragLeave = (e) => { if (!e.currentTarget.contains(e.relatedTarget)) sendEvent(drop, "over:0"); };
      props.onDrop = async (e) => {
        if (!carriesFiles(e)) return;
        e.preventDefault();
        sendEvent(drop, "over:0");
        const paths = await storeFiles(e.dataTransfer.files);
        if (paths.length) sendEvent(drop, paths.join("\n"));
      };
    }
    if (n.tap && (n.params || {}).tapCount === "2") {
      // `onTapGesture(count: 2)`: a double tap.
      props["data-tap"] = n.tap;
      props.onDoubleClick = () => sendEvent(n.tap, "");
    } else if (n.tap) {
      props["data-tap"] = n.tap; // exposed for headless smoke tests
      props.onClick = (e) => {
        e.stopPropagation();
        sendEvent(n.tap, "");
      };
      // A tap leaves a text field focused, as SwiftUI's buttons do on iOS
      // and the Mac (a composer's send button, a completion picked above
      // it, which then puts the caret after what it inserted): the press
      // doesn't move the browser's focus to the page.
      props.onMouseDown = (e) => {
        const focused = document.activeElement;
        if (focused && (focused.tagName === "TEXTAREA" || focused.tagName === "INPUT")) e.preventDefault();
      };
      // Web-idiomatic press feedback on tappable regions.
      props.className = ((props.className || "") + " iso-tap").trim();
      // A row's button of the automatic style, two columns wide: the Mac's
      // push button (a Form's on the Mac), not the iPhone's tinted words.
      const pp = n.params || {};
      if (pp.disabled === "1") { props["data-disabled"] = "1"; props.style = { ...(props.style || {}), cursor: "default" }; }
      if (inListCell && pp.button === "automatic" && pp.role !== "destructive" && isDesktop()) {
        props.className += " iso-mac-push";
        Object.assign(props.style, {
          padding: "3px 12px", borderRadius: 6, alignSelf: n.expandW ? props.style.alignSelf : "flex-start",
          fontSize: 13, lineHeight: "18px",
        });
      }
      // List rows keep their list's corners (an inset group rounds only its
      // first and last row); other tappables get a soft press shape.
      if (props.style.borderRadius == null && (n.params || {}).cell == null) props.style.borderRadius = 8;
    }
    return props;
  }

  // A text input holding local state between keystroke echoes so re-renders
  // from Swift don't reset the caret — but a PROGRAMMATIC guest change (a new
  // serialized value that is neither the current text nor an in-flight edit
  // echoing back, e.g. a chat composer clearing its draft on send) applies
  // immediately, focused or not. The vertical-axis form
  // (`TextField(_:text:axis: .vertical)`, params.axis "v") renders a textarea
  // that grows with its content between minLines and maxLines
  // (`.lineLimit(1...6)`), then scrolls internally.
  function TextInput({ n }) {
    const [value, setValue] = R.useState(n.v || "");
    const pending = R.useRef([]);
    const lastSerialized = R.useRef(n.v || "");
    const areaRef = R.useRef(null);
    R.useEffect(() => {
      const v = n.v || "";
      if (v === lastSerialized.current) return;
      lastSerialized.current = v;
      setValue((current) => {
        if (v === current) {
          pending.current = [];
          return current;
        }
        const echo = pending.current.indexOf(v);
        if (echo >= 0) {
          // An older keystroke echoing back; the local text is newer.
          pending.current.splice(0, echo + 1);
          return current;
        }
        pending.current = [];
        return v;
      });
    }, [n.v]);
    const p = n.params || {};
    const multiline = p.axis === "v";
    // `TextEditor`: fills its container and scrolls inside — no line cap.
    const editor = p.editor === "1";
    const lineHeight = (textSize(n) || 15) * 1.35;
    const fit = () => {
      const el = areaRef.current;
      if (!el || editor) return;
      el.style.height = "auto";
      const max = Number(p.maxLines || 5) * lineHeight + (p.fieldStyle === "plain" ? 0 : 14);
      el.style.height = `${Math.min(el.scrollHeight, max)}px`;
      el.style.overflowY = el.scrollHeight > max ? "auto" : "hidden";
    };
    R.useLayoutEffect(() => { if (multiline) fit(); });
    // `.textFieldStyle(.plain)`: the text alone — no bezel, no background —
    // for a field that sits inside its own bubble.
    // The default (`.automatic`) draws no bezel, like SwiftUI's plain field on
    // iOS — apps compose their own bubble — so only `.roundedBorder` gets one.
    const plain = p.fieldStyle !== "roundedBorder";
    const style = {
      ...(n.baseStyle || {}),
      fontSize: textSize(n) || 15,
      padding: plain ? 0 : "7px 10px",
      border: plain ? "none" : "1px solid rgba(120,120,128,0.35)",
      borderRadius: plain ? 0 : 8,
      outline: "none",
      background: plain ? "transparent" : "rgba(120,120,128,0.08)",
      color: "inherit",
      minWidth: 0,
      alignSelf: "stretch",
      // Form controls don't inherit the page font (Safari falls back to
      // the UA's serif); pin the system stack like every text node.
      fontFamily: p.mono === "1" ? MONO_FONT : SYSTEM_FONT,
    };
    // `.keyboardType` → inputmode/type hints; `.textInputAutocapitalization`
    // and `.autocorrectionDisabled` → their HTML attributes.
    const keyboardHints = {
      numberPad: { inputMode: "numeric" }, decimalPad: { inputMode: "decimal" },
      phonePad: { inputMode: "tel" }, emailAddress: { inputMode: "email" },
      URL: { inputMode: "url" }, webSearch: { inputMode: "search" },
      numbersAndPunctuation: { inputMode: "decimal" }, asciiCapableNumberPad: { inputMode: "numeric" },
    }[p.keyboard] || {};
    const autocap = p.autocap ? { autoCapitalize: p.autocap === "never" ? "off" : p.autocap } : {};
    const autocorrect = p.autocorrect === "0" ? { autoCorrect: "off", spellCheck: false } : {};
    // `.focused($state)`: the guest's wish drives focus; focus changes go back.
    const focusRef = R.useRef(null);
    R.useEffect(() => {
      const el = focusRef.current || areaRef.current;  // textarea keeps its own ref
      if (!el || !p.focusId) return;
      const want = p.focus === "1";
      if (want && document.activeElement !== el) el.focus();
      else if (!want && document.activeElement === el) el.blur();
    }, [p.focus, p.focusId]);
    const focusHandlers = p.focusId ? {
      onFocus: () => { if (p.focus !== "1") sendEvent(p.focusId, "1"); },
      onBlur: () => { if (p.focus === "1") sendEvent(p.focusId, "0"); },
    } : {};
    const keyUp = p.keys && p.keyUp === "1"
      ? { onKeyUp: (e) => { if (keyPress(p.keys, e, "u")) e.preventDefault(); } }
      : {};
    // `TextField(_:text:selection:)`: the field's selection goes to the
    // guest (params.selId, "start,end" in UTF-16 units, as the DOM counts
    // them), and one the app set (params.sel, "start,end,request") is shown
    // once per request, when the field holds the guest's text of the frame
    // that asked: React puts a new value in after layout effects (which
    // moves the caret to the end), so the request waits for it. Once the
    // guest's text has moved on (the person typed), the request is dropped.
    const reportedSelection = R.useRef("");
    const shownRequest = R.useRef(0);
    const waiting = R.useRef(null);
    const reportSelection = (el) => {
      if (!p.selId || !el) return;
      const selection = `${el.selectionStart},${el.selectionEnd}`;
      if (selection === reportedSelection.current) return;
      reportedSelection.current = selection;
      sendEvent(p.selId, selection);
    };
    R.useLayoutEffect(() => {
      if (p.sel) {
        const [start, end, request] = p.sel.split(",").map(Number);
        if (request > shownRequest.current && (!waiting.current || waiting.current.request !== request)) {
          waiting.current = { start, end, request, text: n.v || "" };
        }
      }
      const wanted = waiting.current;
      const el = focusRef.current || areaRef.current;
      if (!wanted || !el) return;
      if ((n.v || "") !== wanted.text) {
        waiting.current = null;
        shownRequest.current = wanted.request;
        return;
      }
      if (el.value !== wanted.text) return;
      waiting.current = null;
      shownRequest.current = wanted.request;
      el.setSelectionRange(Math.min(wanted.start, el.value.length), Math.min(wanted.end, el.value.length));
      reportedSelection.current = `${el.selectionStart},${el.selectionEnd}`;
    });
    const selectionHandlers = p.selId ? { onSelect: (e) => reportSelection(e.target) } : {};
    const shared = {
      ...keyboardHints, ...autocap, ...autocorrect, ...focusHandlers, ...keyUp, ...selectionHandlers,
      ref: focusRef,
      value,
      placeholder: n.placeholder,
      onChange: (e) => {
        setValue(e.target.value);
        pending.current.push(e.target.value);
        if (n.edit) sendEvent(n.edit, e.target.value);
        // The caret typing moved, after the text it is in.
        reportSelection(e.target);
      },
      // `.onSubmit`: Enter submits (no newline); Shift/Alt+Enter inserts a
      // newline in a multi-line field (the Messages composer shape).
      onKeyDown: (e) => {
        // `.onKeyPress`: the app sees the key first; one it takes is not typed.
        if (p.keys && keyPress(p.keys, e, e.repeat ? "r" : "d")) {
          e.preventDefault();
          return;
        }
        if (e.key !== "Enter" || e.isComposing) return;
        if (multiline && (e.shiftKey || e.altKey)) return;
        if (p.submit) {
          e.preventDefault();
          sendEvent(p.submit, "");
        } else if (multiline && !e.shiftKey && !e.altKey) {
          // No submit handler: Enter keeps its newline.
        }
      },
    };
    if (editor) {
      return h("textarea", {
        ...shared,
        ref: areaRef,
        spellCheck: false,
        autoCapitalize: "off",
        autoCorrect: "off",
        style: {
          ...style,
          lineHeight: `${lineHeight}px`,
          resize: "none",
          flex: "1 1 0",
          minHeight: 0,
          height: "100%",
          boxSizing: "border-box",
          overflow: "auto",
          whiteSpace: "pre",
          tabSize: 4,
        },
      });
    }
    if (multiline) {
      return h("textarea", {
        ...shared,
        ref: areaRef,
        rows: Number(p.minLines || 1),
        style: {
          ...style,
          lineHeight: `${lineHeight}px`,
          resize: "none",
        },
      });
    }
    // A `SecureField`: the browser's password input (masked, offered to
  // its password manager).
  if (p.secure === "1") return h("input", { ...shared, type: "password", autoComplete: "current-password", style });
  return h("input", { ...shared, type: n.searchStyle ? "search" : "text", style });
  }

  // A DOM key event as `KeyPress` hears it (KeyPress(hostValue:)): phase and
  // modifier letters, the key's character (AppKit's private-use characters
  // for the keys that type nothing), the characters it types; true when
  // the app took it. Modifier keys alone and IME composition are not keys.
  const KEY_EQUIVALENTS = {
    Enter: "\r", Backspace: "\u007f", Delete: "\uf728", Escape: "\u001b", Tab: "\t",
    ArrowUp: "\uf700", ArrowDown: "\uf701", ArrowLeft: "\uf702", ArrowRight: "\uf703",
    Home: "\uf729", End: "\uf72b", PageUp: "\uf72c", PageDown: "\uf72d", Clear: "\uf739",
  };
  function keyPress(id, e, phase) {
    if (e.isComposing || e.keyCode === 229) return false;
    const named = KEY_EQUIVALENTS[e.key];
    if (!named && [...e.key].length !== 1) return false;
    const key = named || e.key;
    let mods = phase;
    if (e.shiftKey) mods += "s";
    if (e.ctrlKey) mods += "c";
    if (e.altKey) mods += "o";
    if (e.metaKey) mods += "m";
    if (e.getModifierState && e.getModifierState("CapsLock")) mods += "l";
    let chars = named || e.key;
    // Control letters type their control character, as AppKit reports them.
    if (e.ctrlKey && !named && /^[a-zA-Z@\[\\\]^_]$/.test(e.key)) {
      chars = String.fromCharCode(e.key.toUpperCase().charCodeAt(0) & 0x1f);
    }
    return !!sendKey(id, `${mods}\u001f${key}\u001f${chars}`);
  }

  // Syntax highlighting for the code editor: a small Swift tokenizer
  // (comments, strings with interpolation, keywords, attributes, numbers,
  // capitalized type names), emitted as spans over the textarea's text.
  const SWIFT_KEYWORDS = new Set(("associatedtype class deinit enum extension func import init inout internal let " +
    "operator private protocol public static struct subscript typealias var fileprivate open some any " +
    "break case continue default defer do else fallthrough for guard if in repeat return switch where while " +
    "as catch false is nil rethrows super self Self throw throws true try await async actor macro " +
    "convenience dynamic final indirect lazy mutating nonmutating optional override required weak unowned").split(" "));
  function highlightSwift(source, dark) {
    const c = dark
      ? { kw: "#fc5fa3", str: "#fc6a5d", com: "#6c7986", num: "#d0bf69", type: "#5dd8ff", attr: "#fd8f3f", txt: "rgba(255,255,255,0.92)" }
      : { kw: "#ad3da4", str: "#d12f1b", com: "#5d6c79", num: "#272ad8", type: "#3f6e75", attr: "#947100", txt: "rgba(0,0,0,0.9)" };
    const out = [];
    const re = /(\/\/[^\n]*|\/\*[\s\S]*?\*\/)|("(?:\\.|[^"\\\n])*")|(@[A-Za-z_]\w*)|(\b\d[\d_]*(?:\.\d+)?\b)|(\b[A-Za-z_]\w*\b)/g;
    let last = 0, m, key = 0;
    while ((m = re.exec(source))) {
      if (m.index > last) out.push(source.slice(last, m.index));
      let color = null;
      if (m[1]) color = c.com;
      else if (m[2]) color = c.str;
      else if (m[3]) color = c.attr;
      else if (m[4]) color = c.num;
      else if (m[5]) color = SWIFT_KEYWORDS.has(m[5]) ? c.kw : (/^[A-Z]/.test(m[5]) ? c.type : null);
      out.push(color ? h("span", { key: key++, style: { color } }, m[0]) : m[0]);
      last = re.lastIndex;
    }
    if (last < source.length) out.push(source.slice(last));
    out.push("\n");  // a trailing newline keeps the underlay as tall as the textarea's last line
    return out;
  }

  // The code editor host view (`CodeEditor(text:fileName:)` on the web): a
  // transparent-text textarea for input and caret over a <pre> underlay
  // carrying the highlighted copy; both share font metrics and scroll.
  function CodeEditor({ n }) {
    const [value, setValue] = R.useState(n.v || "");
    const pending = R.useRef([]);
    const lastSerialized = R.useRef(n.v || "");
    const preRef = R.useRef(null);
    R.useEffect(() => {
      const v = n.v || "";
      if (v === lastSerialized.current) return;
      lastSerialized.current = v;
      setValue((current) => {
        if (v === current) { pending.current = []; return current; }
        const echo = pending.current.indexOf(v);
        if (echo >= 0) { pending.current.splice(0, echo + 1); return current; }
        pending.current = [];
        return v;
      });
    }, [n.v]);
    const dark = document.documentElement.dataset.theme === "dark"
      || (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
    const lang = (n.params || {}).lang || "plain";
    const metrics = { fontFamily: MONO_FONT, fontSize: 13, lineHeight: "19px", tabSize: 4, whiteSpace: "pre", padding: "12px 14px", margin: 0, boxSizing: "border-box" };
    const onChange = (e) => {
      const next = e.target.value;
      pending.current.push(next);
      setValue(next);
      sendEvent(n.edit, next);
    };
    // Tab inserts spaces instead of leaving the field.
    const onKeyDown = (e) => {
      if (e.key !== "Tab") return;
      e.preventDefault();
      const el = e.target, start = el.selectionStart, end = el.selectionEnd;
      const next = value.slice(0, start) + "    " + value.slice(end);
      pending.current.push(next);
      setValue(next);
      sendEvent(n.edit, next);
      requestAnimationFrame(() => { el.selectionStart = el.selectionEnd = start + 4; });
    };
    const onScroll = (e) => { if (preRef.current) { preRef.current.scrollTop = e.target.scrollTop; preRef.current.scrollLeft = e.target.scrollLeft; } };
    return h("div", { style: { position: "relative", flex: "1 1 0", minHeight: 0, alignSelf: "stretch", width: "100%", height: "100%", overflow: "hidden", background: dark ? "#1f1f22" : "#fbfbfc" } },
      h("pre", { ref: preRef, "aria-hidden": true, style: { ...metrics, position: "absolute", inset: 0, overflow: "hidden", color: dark ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.9)", pointerEvents: "none" } },
        lang === "swift" ? highlightSwift(value, dark) : value + "\n"),
      h("textarea", {
        value, onChange, onKeyDown, onScroll, spellCheck: false, autoCapitalize: "off", autoCorrect: "off", autoComplete: "off",
        "aria-label": (n.params || {}).a11yLabel || "Code",
        style: { ...metrics, position: "absolute", inset: 0, width: "100%", height: "100%", border: "none", outline: "none", resize: "none",
          background: "transparent", color: "transparent", caretColor: dark ? "#fff" : "#000", overflow: "auto" },
      }));
  }

  // A segmented control (`.pickerStyle(.segmented)`, inline or in a bar).
  // In a Form's or a List's row it takes the row's width (`wide`), as iOS's.
  function Segmented({ options, selected, dark, onSelect, compact, wide }) {
    return h("div", {
      role: "tablist",
      style: {
        display: wide ? "flex" : "inline-flex", padding: 2, borderRadius: wide ? 9 : 8, gap: 1,
        ...(wide ? { flex: "1 1 auto", alignSelf: "stretch", width: "100%", boxSizing: "border-box" } : {}),
        background: dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.06)",
        fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
      },
    }, options.map((label, i) => h("button", {
      key: i,
      role: "tab",
      "aria-selected": i === selected,
      onClick: () => onSelect(i),
      style: {
        border: "none", cursor: "pointer", borderRadius: wide ? 7 : 6,
        padding: compact ? "3px 12px" : wide ? "6px 14px" : "4px 14px", fontSize: wide ? 15 : 13, fontWeight: 500,
        ...(wide ? { flex: "1 1 0" } : {}),
        background: i === selected ? (dark ? "rgba(120,120,128,0.8)" : "#fff") : "none",
        color: dark ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.85)",
        boxShadow: i === selected ? "0 1px 3px rgba(0,0,0,0.15)" : "none",
      },
    }, label)));
  }

  // The centre slot for a `.principal` view of the app's own. Taller than
  // the bar, it is centred on the bar's row and may hang above it — into
  // the status-bar area on a phone. In a plain browser tab there is nothing
  // above the page, so an overhang past the top is pushed down to the edge
  // (the pill below keeps its overlap).
  function PrincipalSlot({ dark, children }) {
    const ref = R.useRef(null);
    const [shift, setShift] = R.useState(0);
    R.useLayoutEffect(() => {
      const el = ref.current;
      if (!el) return undefined;
      const measure = () => {
        const view = el.firstElementChild;
        if (!view) return;
        // The view's painted top: its own box or, when an `.offset` inside
        // moves the content, the highest of its descendants (the box's rect
        // does not include a child's translate).
        // Wrapper boxes paint nothing: only leaves and filled boxes count.
        let top = Infinity;
        const nodes = view.querySelectorAll("*");
        for (let i = 0; i < nodes.length && i < 400; i++) {
          const node = nodes[i];
          const r = node.getBoundingClientRect();
          if (r.height <= 0 || r.top >= top) continue;
          if (node.children.length === 0) { top = r.top; continue; }
          const cs = getComputedStyle(node);
          if ((cs.backgroundColor && cs.backgroundColor !== "rgba(0, 0, 0, 0)") || (cs.borderTopWidth && cs.borderTopWidth !== "0px") || cs.backgroundImage !== "none") top = r.top;
        }
        if (top === Infinity) top = view.getBoundingClientRect().top;
        setShift(Math.max(0, Math.round(-(top - shift))));
      };
      measure();
      const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(measure);
      if (observer) observer.observe(el);
      return () => { if (observer) observer.disconnect(); };
    });
    return h("div", {
      ref,
      className: "iso-principal",
      style: {
        display: "inline-flex", alignItems: "center", justifyContent: "center", maxWidth: "100%", overflow: "visible", fontWeight: 400,
        color: dark ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.85)",
        transform: shift ? `translateY(${shift}px)` : undefined,
      },
    }, children);
  }

  // The bar row: the title sits centred on the whole bar (an absolute
  // box), inset by the wider of the two clusters so it never runs under a
  // Back pill or a trailing glyph — the way iOS centres a title and only
  // shortens it when the items press in. Measured after layout.
  function CenteredBar({ style, children }) {
    const ref = R.useRef(null);
    const titleRef = R.useRef(null);
    const [insets, setInsets] = R.useState({ left: 64, right: 64 });
    R.useLayoutEffect(() => {
      const el = ref.current;
      if (!el || el.children.length < 3) return undefined;
      const measure = () => {
        const bar = el.getBoundingClientRect().width;
        const leftW = Math.round(el.children[0].getBoundingClientRect().width) + 8;
        const rightW = Math.round(el.children[2].getBoundingClientRect().width) + 8;
        const title = titleRef.current ? titleRef.current.scrollWidth : 0;
        // Centred on the bar when the title fits between equal insets;
        // otherwise it moves over towards the narrower cluster (and then
        // shortens), the way UIKit places a title next to a Back button.
        const even = Math.max(leftW, rightW);
        const next = title + 2 * even <= bar ? { left: even, right: even } : { left: leftW, right: rightW };
        setInsets((current) => (current.left === next.left && current.right === next.right ? current : next));
      };
      measure();
      const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(measure);
      if (observer) { observer.observe(el); observer.observe(el.children[0]); observer.observe(el.children[2]); if (titleRef.current) observer.observe(titleRef.current); }
      return () => { if (observer) observer.disconnect(); };
    });
    const [leading, centre, trailing] = R.Children.toArray(children);
    return h("div", { ref, style }, leading,
      h("div", { style: { position: "absolute", left: insets.left, right: insets.right, top: 0, bottom: 0, display: "flex", alignItems: "center", justifyContent: "center", minWidth: 0, pointerEvents: "none" } },
        h("div", { ref: titleRef, style: { pointerEvents: "auto", minWidth: 0, maxWidth: "100%", display: "flex", justifyContent: "center" } }, centre)),
      trailing);
  }

  function navBar(n, kids) {
    const p = n.params || {};
    const dark = p.dark === "1";
    const desktop = isDesktop();
    // Under a visible large title the bar is just its buttons over the
    // content (iOS); it takes its material once the title collapses.
    const largeShowing = p.large === "1" && Number(p.inlineAlpha || 1) < 0.5;
    const bar = {
      // Three columns with equal sides: the title is centred on the bar,
      // not between clusters of different width (a Back pill and a glyph).
      display: "flex", justifyContent: "space-between", alignItems: "center", position: "relative", width: "100%", height: 52, flex: "none",
      boxSizing: "border-box", padding: "0 8px",
      // Transparent, no hairline: the bar is its buttons and title over the
      // content on every canvas (the web apps' choice); a principal
      // view may reach above or below the row.
      background: "transparent", overflow: "visible",
      color: dark ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.85)",
      fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
    };
    // Bar items read as tappable: a tinted pill (fill + radius), like a
    // bordered button, rather than a bare glyph.
    // Phone: tinted pills (a bordered button). Desktop: borderless
    // monochrome items that tint on hover/press, the macOS toolbar's.
    const button = desktop ? {
      border: "none", background: "none", color: dark ? "rgba(255,255,255,0.85)" : "rgba(0,0,0,0.75)", fontSize: 13,
      fontWeight: 500, cursor: "pointer", padding: "5px 9px", borderRadius: 6, flex: "0 0 auto",
      minWidth: 28, lineHeight: "18px", margin: "0 1px",
      fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
    } : {
      // iOS 26's shape: 44pt capsules and circles, translucent with a
      // hairline, in the label colour (no liquid glass).
      border: `1px solid ${dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.08)"}`,
      background: dark ? "rgba(60,60,67,0.55)" : "rgba(255,255,255,0.72)",
      backdropFilter: MATERIAL_BLUR, WebkitBackdropFilter: MATERIAL_BLUR,
      color: dark ? "rgba(255,255,255,0.95)" : "rgba(0,0,0,0.88)", fontSize: 17,
      fontWeight: 500, cursor: "pointer", padding: "0 17px", borderRadius: 22, flex: "0 0 auto",
      minWidth: 44, height: 44, lineHeight: "42px", margin: "0 2px", boxSizing: "border-box",
      boxShadow: dark ? "0 1px 6px rgba(0,0,0,0.25)" : "0 1px 6px rgba(0,0,0,0.08)",
      fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
    };
    // Toolbar items (`ToolbarItem(placement:)`): newline-joined title lists.
    const split = (key) => (p[key] ? p[key].split("\n") : []);
    const leading = split("leading");
    const trailing = split("trailingItems");
    // `.principal`: the trailing item at this index renders centered in
    // place of the title (a tappable pill), the way a macOS/iOS bar does.
    const principal = p.principal === "" || p.principal == null ? -1 : Number(p.principal);
    // Segmented toolbar items: per trailing item, U+001F-joined labels.
    const segments = split("segments").map((s) => (s ? s.split("\u001f") : []));
    const segmentSelected = split("segmentSelected").map((s) => Number(s) || 0);
    const prominent = split("prominent");
    // A disabled item (`.disabled(true)` on its button): greyed as iOS
    // greys a bar button, and no press.
    const leadingDisabled = split("leadingDisabled");
    const trailingDisabled = split("trailingDisabled");
    const disabledItem = { color: dark ? "rgba(255,255,255,0.3)" : "rgba(0,0,0,0.3)", cursor: "default" };
    // `.accessibilityLabel` on a bar button → aria-label (glyph-only items
    // like ✎ / ▶︎ read as "Edit" / "Run" to assistive tech and the tap tool).
    const leadingLabels = split("leadingLabels");
    const trailingLabels = split("trailingLabels");
    const leadingSymbols = split("leadingSymbols");
    const trailingSymbols = split("trailingSymbols");
    // An item whose label is a symbol: a 36px circle with the icon.
    const circle = desktop
      ? { ...button, width: 30, height: 28, minWidth: 30, padding: 0, display: "inline-flex", alignItems: "center", justifyContent: "center" }
      : { ...button, width: 44, height: 44, minWidth: 44, padding: 0, borderRadius: 22, display: "inline-flex", alignItems: "center", justifyContent: "center" };
    const itemContent = (title, symbol) => (symbol && SYMBOLS[symbol]) ? symbolSVG(h, symbol, desktop ? 17 : 21, "currentColor", 600, { verticalAlign: "0" }) : title;
    const itemStyle = (symbol) => (symbol && SYMBOLS[symbol]) ? circle : button;
    const trailingItem = (i, extra) => segments[i] && segments[i].length
      ? h(Segmented, {
          key: `t${i}`, options: segments[i], selected: segmentSelected[i] || 0, dark, compact: true,
          onSelect: (j) => sendEvent(n.edit, `segment:${i}:${j}`),
        })
      : h("button", {
          key: `t${i}`, className: "iso-bar-item",
          "aria-label": trailingLabels[i] || undefined,
          disabled: trailingDisabled[i] === "1",
          style: { ...itemStyle(trailingSymbols[i]), ...(prominent[i] === "1" ? { fontWeight: 600 } : {}), ...(trailingDisabled[i] === "1" ? disabledItem : {}), ...(extra || {}) },
          onClick: () => sendEvent(n.edit, `trailingItem:${i}`),
        }, itemContent(trailing[i] || "", trailingSymbols[i]));
    // Symmetric side clusters keep the title centered.
    const side = { display: "flex", alignItems: "center", minWidth: 64 };
    // A split column's bar at regular width, the Mac's: the sidebar toggle
    // (at the end of the sidebar's bar, or the start of the detail's while
    // the sidebar is hidden) and the detail's title at its leading edge.
    const sidebarToggle = n.onToggleSidebar ? h("button", {
      key: "sidebar", className: "iso-bar-item", style: circle, onClick: n.onToggleSidebar,
      "aria-label": n.desktopColumn === "sidebar" ? "Hide Sidebar" : "Show Sidebar",
    }, symbolSVG(h, "sidebar.left", 17, "currentColor", 500, { verticalAlign: "0" }) || "◧") : null;
    const leadingTitle = desktop && !!n.desktopColumn && n.desktopColumn !== "sidebar" && principal < 0 && !n.pill && !!p.title;
    return h(CenteredBar, { style: bar },
      h("div", { style: side },
        n.desktopColumn !== "sidebar" ? sidebarToggle : null,
        n.pill && desktop && p.title
          ? h("span", { key: "lt", style: { fontWeight: 600, fontSize: 15, padding: "0 6px", whiteSpace: "nowrap" } }, p.title)
          : null,
        p.back === "1"
          // iOS 26's Back: the chevron alone in a round button (its title
          // is for assistive tech); the desktop keeps the word.
          ? h("button", { key: "back", className: "iso-bar-item", "aria-label": "Back",
              style: desktop ? { ...button, display: "inline-flex", alignItems: "center", gap: 2, paddingLeft: 6, paddingRight: 9 } : circle,
              onClick: () => (n.onBack ? n.onBack() : sendEvent(n.edit, "back")) },
              symbolSVG(h, "chevron.left", desktop ? 17 : 21, "currentColor", 600, { verticalAlign: "0" }), desktop ? "Back" : null)
          : null,
        leading.map((title, i) => n.hiddenLeading && n.hiddenLeading.has(i) ? null : h("button", {
          key: `l${i}`, className: "iso-bar-item", "aria-label": leadingLabels[i] || undefined,
          disabled: leadingDisabled[i] === "1",
          style: { ...itemStyle(leadingSymbols[i]), ...(leadingDisabled[i] === "1" ? disabledItem : {}) },
          onClick: () => sendEvent(n.edit, `leading:${i}`),
        }, itemContent(title, leadingSymbols[i]))),
        leadingTitle
          ? h("div", {
              key: "title",
              style: { display: "flex", flexDirection: "column", minWidth: 0, padding: "0 8px", lineHeight: 1.2 },
            },
              h("span", { style: { fontWeight: 700, fontSize: 15, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" } }, p.title),
              p.subtitle ? h("span", { style: { fontSize: 11, opacity: 0.55, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" } }, p.subtitle) : null)
          : null),
      h("div", {
        style: {
          textAlign: "center", fontWeight: 600, fontSize: 16,
          // A principal view of the app's own may hang below the bar (a name
          // pill under an avatar): only words are clipped.
          overflow: p.principalContent === "1" ? "visible" : "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
          // Explicit shrinkability: overflow:hidden already zeroes the flex
          // minimum (the automatic min-size only applies to visible
          // overflow), but state it outright so a future overflow change
          // can't silently let a long nowrap title push the trailing
          // toolbar cluster off-viewport on narrow screens.
          minWidth: 0,
          opacity: p.large === "1" ? Number(p.inlineAlpha || 1) : 1,
        },
      }, n.pill
        ? h(Segmented, {
            options: n.pill.options, selected: n.pill.selected, dark, compact: true,
            onSelect: n.pill.onSelect,
          })
        : !leadingTitle && principal < 0 && p.subtitle
        ? h("div", { style: { display: "flex", flexDirection: "column", lineHeight: 1.15 } },
            h("span", null, p.title || ""),
            h("span", { style: { fontSize: 12, fontWeight: 400, opacity: 0.6 } }, p.subtitle))
        : principal >= 0 && p.principalContent === "1" && (n.principalView || (kids && kids.length))
        // `.principal` with a view of its own: drawn as the app made it.
        ? h(PrincipalSlot, { key: "principal", dark }, n.principalView || kids[0])
        : principal >= 0
        // `.principal`: a title-styled button (the name, an avatar), no pill.
        ? trailingItem(principal, {
            fontWeight: 600, fontSize: 16, padding: "4px 8px", borderRadius: 8, background: "none",
            color: dark ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.85)",
          })
        : leadingTitle ? "" : (p.title || "")),
      h("div", { style: { ...side, justifyContent: "flex-end" } },
        trailing.map((title, i) => i === principal || (n.hiddenTrailing && n.hiddenTrailing.has(i)) ? null : trailingItem(i)),
        // A bottom bar's buttons, in the Mac's toolbar.
        (n.liftedButtons || []).map((b, i) => h("button", {
          key: `lift${i}`, className: "iso-bar-item", style: itemStyle(b.symbol), "aria-label": b.label || undefined,
          onClick: () => sendEvent(b.tap, ""),
        }, itemContent(b.label || "•", b.symbol))),
        n.desktopColumn === "sidebar" ? sidebarToggle : null));
  }

  // A screen's `.bottomBar` that is only buttons (and the room between
  // them): what the desktop draws in the column's bar instead.
  function liftedBottomBar(n) {
    const p = n.params || {};
    if (n.k !== "stack" || p.inset !== "bottom" || !p.bottomBar) return false;
    const kinds = p.bottomBar.split("\n");
    return kinds.includes("button") && kinds.every((k) => k === "button" || k === "fixed" || k === "flex");
  }

  // The buttons of the bottom bar in a navigation stack's content (through
  // the wrappers and insets around the screen), as bar items: what to send,
  // the symbol, the name.
  function liftedBarButtons(start) {
    let found = null;
    const visit = (node, depth) => {
      if (!node || found || depth > 24) return;
      if (liftedBottomBar(node)) { found = node; return; }
      if (node.k === "scroll" || (node.k === "hostView" && node.view === "navstack")) return;
      for (const c of node.ch || []) visit(c, depth + 1);
    };
    visit(start, 0);
    if (!found) return [];
    const kinds = found.params.bottomBar.split("\n").filter((k) => k !== "fixed");
    const row = (((found.ch || [])[1] || {}).ch || [])[0] || {};
    const first = (node, test) => {
      if (!node) return null;
      if (test(node)) return node;
      for (const c of node.ch || []) { const hit = first(c, test); if (hit) return hit; }
      return null;
    };
    return kinds.map((kind, i) => kind === "button" ? (row.ch || [])[i] : null).filter(Boolean).map((button) => {
      const tap = first(button, (x) => !!x.tap);
      const symbol = first(button, (x) => !!(x.params && x.params.symbol));
      const named = first(button, (x) => !!(x.params && x.params.a11yLabel));
      return tap ? { tap: tap.tap, symbol: symbol ? symbol.params.symbol : "", label: named ? named.params.a11yLabel : "" } : null;
    }).filter(Boolean);
  }

  function tabBar(n) {
    const p = n.params || {};
    const count = Number(p.count || 0);
    const selected = Number(p.selected || 0);
    const tabs = [];
    for (let i = 0; i < count; i++) {
      const active = i === selected;
      tabs.push(h("button", {
        key: i,
        onClick: () => sendEvent(n.edit, String(i)),
        style: {
          flex: 1, border: "none", background: "none", cursor: "pointer",
          display: "flex", flexDirection: "column", alignItems: "center", gap: 2,
          padding: "7px 0 5px", fontSize: 11, opacity: active ? 1 : 0.45,
          color: active ? "var(--iso-tint, #0a84ff)" : "rgba(0,0,0,0.55)",
        },
      },
        p["glyph" + i]
          ? h("span", { style: { fontSize: 22, lineHeight: "24px" } }, p["glyph" + i])
          : p["icon" + i]
            ? h("img", { src: `${assetBase}${p["icon" + i]}.png`, style: { width: 24, height: 24, objectFit: "contain" } })
            : null,
        h("span", null, p["label" + i] || "")));
    }
    return h("div", {
      style: {
        display: "flex", width: "100%", flex: "none",
        background: "rgba(249,249,249,0.94)", borderTop: "1px solid rgba(0,0,0,0.12)",
      },
    }, tabs);
  }

  // Semantic navigation (`navstack`) → the web idiom: a compact header bar
  // (back, leading items, centered title, trailing items) shown when it has
  // content, a large-title heading + search row unless the title mode is
  // inline, then the content column. Events ride the node's host-event
  // channel: "back", "leading:<i>", "trailingItem:<i>", "search:<text>".
  // `.tabBarOnly`: the tabs pill is handed to the selected tab's own
  // navigation bar (one bar row: leading cluster, centered pill, trailing
  // cluster — the macOS window-toolbar shape) when that tab's root is a
  // NavigationStack; otherwise the TabView draws its own strip.
  let pendingTabPill = null;

  function navStack(n, key, kids, ownsEdgeScroll) {
    const p = n.params || {};
    let pill = null;
    // The tab root is wrapped in a content box: navstack sits 1–3 levels
    // below the tabs node.
    if (pendingTabPill && !pendingTabPill.consumed && renderDepth - pendingTabPill.depth <= 2) {
      pendingTabPill.consumed = true;
      pill = pendingTabPill;
    }
    const dark = p.dark === "1";
    const depth = Number(p.depth || 0);
    const inline = p.displayMode === "inline" || isDesktop();
    // The split column this stack is the root of (regular width).
    const deskColumn = !isDesktop() ? null
      : desktopColumnStacks.get(n) || (currentDesktopColumn && !currentDesktopColumn.taken && !columnRootStack(currentDesktopColumn.node) ? currentDesktopColumn : null);
    if (deskColumn) deskColumn.taken = true;
    // A sheet's stack on the desktop, the Mac's: its title at the top
    // leading edge, its cancellation, confirmation and destructive actions
    // as push buttons along the bottom at the trailing end (the
    // confirmation last, in the accent colour), not in the bar.
    const macSheet = isDesktop() && presentationDepth > 0 && depth === 0;
    const sheetActions = [];
    const movedLeading = new Set(), movedTrailing = new Set();
    if (macSheet) {
      const places = (key) => (p[key] ? p[key].split("\n") : []);
      const bottom = (place) => place === "cancellationAction" || place === "confirmationAction" || place === "destructiveAction";
      const leadingTitles = p.leading ? p.leading.split("\n") : [];
      const trailingTitles = p.trailingItems ? p.trailingItems.split("\n") : [];
      const leadingOff = places("leadingDisabled"), trailingOff = places("trailingDisabled");
      places("leadingPlacements").forEach((place, i) => {
        if (bottom(place)) {
          movedLeading.add(i);
          sheetActions.push({ title: leadingTitles[i] || "", place, event: `leading:${i}`, disabled: leadingOff[i] === "1" });
        }
      });
      places("trailingPlacements").forEach((place, i) => {
        if (bottom(place) && String(i) !== String(p.principal)) {
          movedTrailing.add(i);
          sheetActions.push({ title: trailingTitles[i] || "", place, event: `trailingItem:${i}`, disabled: trailingOff[i] === "1" });
        }
      });
      // Cancel, then whatever else, then the confirmation.
      const rank = (a) => a.place === "cancellationAction" ? 0 : a.place === "confirmationAction" ? 2 : 1;
      sheetActions.sort((a, b) => rank(a) - rank(b));
    }
    const leading = p.leading ? p.leading.split("\n") : [];
    const trailing = p.trailingItems ? p.trailingItems.split("\n") : [];
    // At its root inside a compact split view, this bar carries the split's
    // Back (to the previous column) — the phone shape of a split detail.
    const splitBack = depth === 0 && currentSplitBack ? currentSplitBack.back : null;
    // On the desktop a bottom bar's buttons join this bar (the Mac has its
    // toolbar where a phone has the bottom bar).
    const liftedButtons = isDesktop() ? liftedBarButtons((n.ch || [])[0]) : [];
    const showBar = depth > 0 || leading.length > 0 || trailing.length > 0 || inline || !!pill || !!splitBack
      || !!(deskColumn && deskColumn.toggle) || liftedButtons.length > 0;
    // Bar-only chrome pins over the content (the iOS shape): translucent,
    // stationary, extending into the top safe area, with its controls in
    // the 44pt row beneath it; the content flows under it with an inset.
    const pinned = showBar && navStackBarOnly(n);
    // A second child is the `.principal` item's own view (the bar draws it).
    const principalView = p.principalContent === "1" && kids && kids.length > 1 ? kids[kids.length - 1] : null;
    if (principalView) kids = kids.slice(0, -1);
    // `.scrollEdgeEffectStyle(.hard, for: .top)` on the screen's scroll:
    // the bar is an opaque band of the page's ground with a line where it
    // ends (iOS's hard edge), not the soft frost.
    const content = (n.ch || [])[0];
    const scrolled = pinned ? edgeScroll(content) : null;
    // The desktop's bar has the Mac's hard edge too (one column keeps the
    // soft one, as iOS does).
    const hardEdge = !!scrolled && ((scrolled.params || {}).edgeTop === "hard" || isDesktop());
    const rows = [];
    if (showBar) {
      rows.push(h(pinned ? "div" : R.Fragment, pinned ? {
        key: "bar",
        style: {
          // Fixed over a document-scrolled page, which scrolls under it.
          position: docScroll() ? "fixed" : "absolute", top: 0, left: 0, right: 0, zIndex: 5, overflow: "visible",
          ...(docScroll() ? { textShadow: `0 0 10px ${dark ? "#000" : "#fff"}, 0 0 4px ${dark ? "#000" : "#fff"}` } : {}),
          paddingTop: SAFE_TOP, boxSizing: "border-box",
        },
      } : { key: "bar" },
        // The scroll-edge effect: content passing under the bar is frosted
        // by a layer of its own that fades out at the bottom, so the bar
        // has no fill, no hairline and no hard edge over the first row.
        // (Not on a document-scrolled page: Safari paints its status bar
        // solid behind any fixed chrome with a fill or a backdrop blur at
        // the page's top edge, hiding the content that should run under it;
        // there the bar is its buttons and title alone, the title with a
        // halo, and Safari's own scroll edge frosts the top.)
        hardEdge ? h("div", {
          key: "band",
          style: {
            position: "absolute", inset: 0, pointerEvents: "none",
            background: backdropFill(content) || (dark ? (isDesktop() ? MAC_DARK_PAGE : "#000") : "#fff"),
            borderBottom: `0.5px solid ${dark ? "rgba(84,84,88,0.65)" : "rgba(60,60,67,0.29)"}`,
          },
        }) : pinned && docScroll() ? h("div", {
          key: "fade",
          // On a document-scrolled page (Safari): no backdrop filter (see
          // above), but the content still fades out under the bar, as iOS
          // 26's soft edge has it — the page's ground over it, easing to
          // nothing a little below the bar.
          style: {
            position: "absolute", left: 0, right: 0, top: 0, bottom: -14, pointerEvents: "none",
            background: `linear-gradient(to bottom, ${backdropFill(content) || (dark ? "#000" : "#fff")} 0%, ${backdropFill(content) || (dark ? "#000" : "#fff")} 62%, transparent 100%)`,
          },
        }) : pinned && !docScroll() ? h("div", {
          key: "frost",
          style: {
            position: "absolute", inset: 0, pointerEvents: "none",
            // From the top of the screen (the status bar's safe area) to
            // the bottom of the bar, easing out: soft enough that the
            // content still reads through it near the bar's lower edge.
            backdropFilter: "blur(6px)", WebkitBackdropFilter: "blur(6px)",
            maskImage: FROST_MASK, WebkitMaskImage: FROST_MASK,
          },
        }) : null,
        navBar({
        edit: n.edit,
        pill,
        onBack: splitBack,
        principalView,
        desktopColumn: deskColumn ? deskColumn.column : macSheet ? "sheet" : null,
        onToggleSidebar: deskColumn ? deskColumn.toggle : null,
        hiddenLeading: movedLeading, hiddenTrailing: movedTrailing,
        liftedButtons,
        params: {
          // No title over the Mac's sidebar: the window's is the detail's.
          title: deskColumn && deskColumn.column === "sidebar" ? "" : inline || !p.title ? (p.title || "") : "",
          subtitle: inline ? (p.subtitle || "") : "",
          back: depth > 0 || splitBack ? "1" : "0",
          dark: p.dark,
          leading: p.leading,
          trailingItems: p.trailingItems,
          leadingLabels: p.leadingLabels,
          trailingLabels: p.trailingLabels,
          leadingSymbols: p.leadingSymbols,
          trailingSymbols: p.trailingSymbols,
          principal: p.principal,
          principalContent: p.principalContent,
          segments: p.segments,
          segmentSelected: p.segmentSelected,
          prominent: p.prominent,
          leadingDisabled: p.leadingDisabled,
          trailingDisabled: p.trailingDisabled,
        },
      })));
    }
    if (isDesktop() && p.displayMode !== "inline" && p.title && showBar) {
      rows.push(h("div", { key: "topgap", style: { height: 12, flex: "none" } }));
    }
    // An iPhone's large title sits under its bar's row even when the row
    // holds nothing.
    if (!isDesktop() && !showBar && !inline && p.title) {
      rows.push(h("div", { key: "emptybar", style: { height: 52, flex: "none" } }));
    }
    if (!inline && p.title) {
      rows.push(h("div", {
        key: "title",
        style: {
          fontSize: 34, fontWeight: 700, padding: p.subtitle ? "6px 16px 0" : "6px 16px 8px",
          color: dark ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.85)",
          fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
        },
      }, p.title));
      // `.navigationSubtitle`: small secondary line under the large title.
      if (p.subtitle) {
        rows.push(h("div", {
          key: "subtitle",
          style: {
            fontSize: 15, padding: "0 16px 8px",
            color: dark ? "rgba(255,255,255,0.55)" : "rgba(0,0,0,0.5)",
            fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
          },
        }, p.subtitle));
      }
    }
    if (p.searchPrompt != null && p.searchPrompt !== "" && isDesktop()) {
      rows.push(h(MacSearchField, {
        key: "search", value: p.searchValue || "", prompt: p.searchPrompt, dark,
        onInput: (text) => sendEvent(n.edit, `search:${text}`),
      }));
    } else if (p.searchPrompt != null && p.searchPrompt !== "") {
      rows.push(h("input", {
        key: "search",
        type: "search",
        defaultValue: p.searchValue || "",
        placeholder: p.searchPrompt,
        onInput: (e) => sendEvent(n.edit, `search:${e.target.value}`),
        style: {
          margin: "0 16px 8px", padding: "7px 10px", fontSize: 15,
          border: "1px solid rgba(120,120,128,0.35)", borderRadius: 8,
          outline: "none", background: "rgba(120,120,128,0.08)",
          color: "inherit",
        },
      }));
    }
    if (pinned) {
      // remount per level: a push swaps the screen
      rows.push(insetContent(`content:${depth}`, kids, ownsEdgeScroll, true));
    } else {
      // The bar and title rows start below the status bar (a home-screen
      // web app draws under it); what they sit over is below it already.
      if (rows.length) rows.unshift(h("div", { key: "safe-top", style: { height: SAFE_TOP, flex: "none" } }));
      rows.push(h("div", {
        key: `content:${depth}`, // remount per level: a push swaps the screen
        style: {
          display: "flex", flexDirection: "column", flex: 1, minHeight: 0, alignSelf: "stretch",
          // Nothing pins over the content here: its edge scroll takes no
          // top inset (an enclosing bar's must not reach it).
          "--iso-inset-top": "0px",
          ...(rows.length > 1 ? { "--iso-safe-top": "0px" } : {}),
        },
      }, kids));
    }
    if (sheetActions.length) {
      rows.push(h("div", {
        key: "sheet-actions",
        // The Mac's sheet keeps its buttons below a hairline, 20pt in.
        style: {
          display: "flex", justifyContent: "flex-end", gap: 8, padding: 20, flex: "none",
          borderTop: `1px solid ${dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)"}`,
        },
      }, sheetActions.map((action) => {
        const confirm = action.place === "confirmationAction";
        const destructive = action.place === "destructiveAction";
        // Disabled, the Mac's push button greys: the default one loses its
        // accent and both take the disabled label colour.
        const off = action.disabled;
        return h("button", {
          key: action.event, className: "iso-bar-item", disabled: off, onClick: () => sendEvent(n.edit, action.event),
          style: {
            minWidth: 72, height: 24, padding: "0 12px", borderRadius: 6, fontSize: 13, fontWeight: confirm ? 600 : 400,
            fontFamily: SYSTEM_FONT, cursor: off ? "default" : "pointer",
            border: confirm && !off ? "none" : `1px solid ${dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.12)"}`,
            background: confirm && !off ? "var(--iso-tint, #0a84ff)" : dark ? "rgba(255,255,255,0.12)" : "#fff",
            color: off ? (dark ? "rgba(255,255,255,0.25)" : "rgba(0,0,0,0.25)") : confirm ? "#fff" : destructive ? "#ff453a" : "inherit",
          },
        }, action.title);
      })));
    }
    return h("div", {
      key,
      "data-navstack": "1",
      style: {
        display: "flex", flexDirection: "column", flex: 1, position: "relative",
        minHeight: 0, minWidth: 0, alignSelf: "stretch", width: "100%",
        color: dark ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.85)",
        ...(pinned ? { "--iso-inset-top": `calc(52px + ${SAFE_TOP})` } : {}),
      },
    }, rows);
  }

  // The Mac's search field (agent_ui's on the Mac): a capsule 36pt tall
  // inset 12pt from the column's sides, a magnifying glass, 13pt type and a
  // clear button once there is text.
  function MacSearchField({ value, prompt, dark, onInput }) {
    const [text, setText] = R.useState(value);
    const change = (next) => { setText(next); onInput(next); };
    const secondary = dark ? "rgba(235,235,245,0.6)" : "rgba(60,60,67,0.6)";
    return h("div", {
      style: {
        display: "flex", alignItems: "center", gap: 6, height: 36, boxSizing: "border-box",
        padding: "0 12px", margin: "0 12px 8px", borderRadius: 18, flex: "none",
        background: dark ? "rgba(235,235,245,0.11)" : "rgba(60,60,67,0.11)",
      },
    },
      symbolSVG(h, "magnifyingglass", 13, secondary, 500, { verticalAlign: "0", flex: "none" }),
      h("input", {
        type: "text", value: text, placeholder: prompt, "aria-label": prompt,
        onInput: (e) => change(e.target.value),
        style: {
          flex: 1, minWidth: 0, border: "none", outline: "none", background: "transparent", padding: 0,
          fontSize: 13, color: "inherit", fontFamily: SYSTEM_FONT,
        },
      }),
      text ? h("button", {
        "aria-label": "Clear the search", onClick: () => change(""),
        style: { border: "none", background: "none", padding: 0, cursor: "pointer", display: "inline-flex", flex: "none" },
      }, symbolSVG(h, "xmark.circle.fill", 13, secondary, 400, { verticalAlign: "0" })) : null);
  }

  // Semantic `navsplit` → three columns (240 | 340 | remainder) with
  // hairline dividers; the sidebar carries the bar tint, like a desktop
  // split view. On a COMPACT container it collapses to a single-pane drill
  // (like SwiftUI's own split view on an iPhone): a tap inside the visible
  // column advances to the next pane, the back row retreats.
  // `.tabViewStyle(.sidebarAdaptable)` (the modern Tab/TabSection form):
  // macOS semantics on the web — ALWAYS a sidebar (TabSections as groups,
  // like the navsplit sidebar column) regardless of width, with the
  // standard collapse/expand toggle at the top leading edge; collapsed,
  // the panes take the full width and the floating toggle brings it back.
  // The collapsed state persists per browser (localStorage). Labels carry
  // SF-symbol text glyphs (`glyph<i>`) mapped by the guest.
  function SidebarTabs({ n, kids }) {
    const p = n.params || {};
    const dark = p.dark === "1";
    const count = Number(p.count || 0);
    const selected = Number(p.selected || 0);
    const [collapsed, setCollapsed] = R.useState(() => {
      try { return localStorage.getItem("iso-sidebar-collapsed") === "1"; }
      catch (_) { return false; }
    });
    const toggle = () => setCollapsed((value) => {
      try { localStorage.setItem("iso-sidebar-collapsed", value ? "0" : "1"); }
      catch (_) {}
      return !value;
    });
    // The macOS sidebar.leading control, inline SVG (crisper than a glyph).
    const toggleButton = (extra) => h("button", {
      key: "toggle",
      title: collapsed ? "Show Sidebar" : "Hide Sidebar",
      onClick: toggle,
      style: {
        border: "none", background: "none", cursor: "pointer", padding: 6,
        borderRadius: 6, display: "flex", alignItems: "center",
        color: dark ? "rgba(255,255,255,0.55)" : "rgba(0,0,0,0.5)",
        ...extra,
      },
    }, h("svg", { width: 18, height: 16, viewBox: "0 0 18 16" },
      h("rect", { x: 0.75, y: 0.75, width: 16.5, height: 14.5, rx: 3, fill: "none", stroke: "currentColor", strokeWidth: 1.5 }),
      h("line", { x1: 6.5, y1: 1, x2: 6.5, y2: 15, stroke: "currentColor", strokeWidth: 1.5 }),
      h("rect", { x: 2, y: 3, width: 3, height: 1.6, rx: 0.8, fill: "currentColor" }),
      h("rect", { x: 2, y: 6, width: 3, height: 1.6, rx: 0.8, fill: "currentColor" })));
    const content = h("div", {
      key: "content",
      style: { display: "flex", flexDirection: "column", flex: 1, minHeight: 0, minWidth: 0, alignSelf: "stretch" },
    }, kids);
    if (collapsed) {
      return h("div", {
        style: { position: "relative", display: "flex", flexDirection: "row", flex: 1, width: "100%", minHeight: 0, alignSelf: "stretch" },
      },
        content,
        h("div", { key: "float", style: { position: "absolute", top: 8, left: 8, zIndex: 20 } },
          toggleButton({ background: dark ? "rgba(30,30,32,0.85)" : "rgba(247,247,247,0.9)", boxShadow: "0 1px 4px rgba(0,0,0,0.25)" })));
    }
    // `.tabViewCustomization`: root items (ungrouped tabs, sections) and
    // the tabs inside a section drag-reorder; the new arrangement goes to
    // the guest as "reorder:<raw>" (guest applies it and re-emits ordered
    // entries) and, when the binding is an @AppStorage, persists in
    // localStorage under the storage key so it survives reloads.
    const custom = p.custom === "1";
    const storageKey = custom ? (p.storageKey || "") : "";
    const [dragging, setDragging] = R.useState(null);
    const [over, setOver] = R.useState(null);
    // Root items in the guest's (already arranged) order.
    const roots = [];
    for (let i = 0; i < count; i++) {
      const section = p["section" + i] || "";
      const sid = p["sid" + i] || "";
      const key = sid ? "s:" + sid : (section ? "t:" + section : "tab:" + i);
      const last = roots[roots.length - 1];
      if (last && last.key === key && (sid || section)) {
        last.tabs.push(i);
      } else {
        roots.push({
          key, section, id: (sid || section) ? sid : (p["cid" + i] || ""),
          isSection: !!(sid || section), tabs: [i],
          pinned: (sid || section) ? p["sfixed" + i] === "1" : p["fixed" + i] === "1",
        });
      }
    }
    const serialize = (rootIds, sectionOrders) => {
      const parts = [];
      if (rootIds.length) parts.push(":" + rootIds.join(","));
      for (const id of Object.keys(sectionOrders).sort()) {
        if (sectionOrders[id].length) parts.push(id + ":" + sectionOrders[id].join(","));
      }
      return parts.join(";");
    };
    const currentArrangement = () => {
      const sectionOrders = {};
      for (const r of roots) {
        if (r.isSection && r.id) sectionOrders[r.id] = r.tabs.map((i) => p["cid" + i] || "").filter(Boolean);
      }
      return { rootIds: roots.map((r) => r.id).filter(Boolean), sectionOrders };
    };
    const commit = (raw) => {
      if (storageKey) { try { localStorage.setItem(storageKey, raw); } catch (_) {} }
      sendEvent(n.edit, "reorder:" + raw);
    };
    R.useEffect(() => {
      if (!storageKey) return;
      let stored = null;
      try { stored = localStorage.getItem(storageKey); } catch (_) {}
      if (stored != null && stored !== (p.arrangement || "")) {
        // First mount: a persisted arrangement wins over the guest default.
        if (!SidebarTabs.synced.has(storageKey)) {
          SidebarTabs.synced.add(storageKey);
          sendEvent(n.edit, "reorder:" + stored);
          return;
        }
      }
      SidebarTabs.synced.add(storageKey);
      try { localStorage.setItem(storageKey, p.arrangement || ""); } catch (_) {}
    }, [storageKey, p.arrangement]);
    const moveWithin = (ids, fromId, toId) => {
      const list = ids.filter((id) => id !== fromId);
      const at = list.indexOf(toId);
      const before = ids.indexOf(fromId) > ids.indexOf(toId);
      list.splice(before ? at : at + 1, 0, fromId);
      return list;
    };
    const dropOn = (target) => {
      if (!dragging || dragging.kind !== target.kind || dragging.id === target.id) return;
      if (dragging.kind === "tab" && dragging.container !== target.container) return;
      const { rootIds, sectionOrders } = currentArrangement();
      if (dragging.kind === "root") {
        commit(serialize(moveWithin(rootIds, dragging.id, target.id), sectionOrders));
      } else {
        sectionOrders[dragging.container] = moveWithin(sectionOrders[dragging.container] || [], dragging.id, target.id);
        commit(serialize(rootIds, sectionOrders));
      }
    };
    const dragProps = (item) => {
      if (!custom || !item.id || item.pinned) return {};
      const token = item.kind + "/" + item.container + "/" + item.id;
      return {
        draggable: true,
        onDragStart: (e) => {
          try { e.dataTransfer.setData("text/plain", token); e.dataTransfer.effectAllowed = "move"; } catch (_) {}
          setDragging(item);
        },
        onDragEnd: () => { setDragging(null); setOver(null); },
        onDragOver: (e) => {
          if (!dragging || dragging.kind !== item.kind || (item.kind === "tab" && dragging.container !== item.container)) return;
          e.preventDefault();
          if (over !== token) setOver(token);
        },
        onDragLeave: () => { if (over === token) setOver(null); },
        onDrop: (e) => { e.preventDefault(); dropOn(item); setDragging(null); setOver(null); },
      };
    };
    const overStyle = (item) => {
      const token = item.kind + "/" + item.container + "/" + item.id;
      return over === token && dragging && dragging.id !== item.id
        ? { boxShadow: "inset 0 2px 0 #0a84ff" } : {};
    };
    const rows = [];
    const tabRow = (i, item) => {
      const active = i === selected;
      const dp = dragProps(item);
      return h("button", {
        key: i,
        onClick: () => sendEvent(n.edit, String(i)),
        ...dp,
        "data-tab": p["label" + i] || "",
        style: {
          display: "flex", alignItems: "center", gap: 9, width: "calc(100% - 12px)",
          margin: "1px 6px", padding: "7px 9px", border: "none",
          cursor: dp.draggable ? "grab" : "pointer",
          borderRadius: 7, textAlign: "left", fontSize: 13.5,
          fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
          background: active ? (dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.08)") : "none",
          color: dark ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.85)",
          opacity: dragging && dragging.kind === item.kind && dragging.id === item.id ? 0.4 : 1,
          ...overStyle(item),
        },
      },
        p["glyph" + i]
          ? h("span", { style: { fontSize: 15, width: 22, textAlign: "center", color: "var(--iso-tint, #0a84ff)" } }, p["glyph" + i])
          : null,
        h("span", null, p["label" + i] || ""));
    };
    for (const root of roots) {
      if (!root.isSection) {
        rows.push(tabRow(root.tabs[0], { kind: "root", container: "", id: root.id, pinned: root.pinned }));
        continue;
      }
      const item = { kind: "root", container: "", id: root.id, pinned: root.pinned };
      const dp = dragProps(item);
      rows.push(h("div", {
        key: "s" + root.tabs[0],
        ...dp,
        "data-section": root.section,
        style: {
          padding: "14px 14px 4px", fontSize: 11, fontWeight: 600,
          textTransform: "uppercase", letterSpacing: "0.4px",
          cursor: dp.draggable ? "grab" : "default",
          color: dark ? "rgba(255,255,255,0.45)" : "rgba(0,0,0,0.45)",
          opacity: dragging && dragging.kind === "root" && dragging.id === root.id ? 0.4 : 1,
          ...overStyle(item),
        },
      }, root.section));
      for (const i of root.tabs) {
        rows.push(tabRow(i, {
          kind: "tab", container: root.id, id: p["cid" + i] || "",
          pinned: p["fixed" + i] === "1",
        }));
      }
    }
    const sidebarBg = dark ? "rgba(30,30,32,0.94)" : "rgba(247,247,247,0.94)";
    return h("div", {
      style: { display: "flex", flexDirection: "row", flex: 1, width: "100%", minHeight: 0, alignSelf: "stretch" },
    },
      h("div", {
        key: "sidebar",
        style: {
          width: 220, flex: "none", display: "flex", flexDirection: "column",
          minHeight: 0, alignSelf: "stretch", background: sidebarBg,
          overflowY: "auto",
        },
      },
        h("div", { key: "head", style: { display: "flex", padding: "6px 6px 2px" } }, toggleButton()),
        rows),
      h("div", {
        key: "d0",
        style: { width: 1, flex: "none", alignSelf: "stretch", background: dark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.12)" },
      }),
      content);
  }

  SidebarTabs.synced = new Set();

  // The compact split's "go back" for the visible pane's own navigation bar
  // (set while the pane renders; navStack shows it as the bar's Back when the
  // pane's stack is at its root).
  let currentSplitBack = null;
  // At regular width, the split column being drawn and its sidebar toggle,
  // for the navigation bar at the column's root: the Mac's window chrome
  // (the toggle at the top of the sidebar, or of the detail while the
  // sidebar is hidden; no title over the sidebar; the detail's title at its
  // leading edge). Taken by the outermost navigation stack in the column.
  let currentDesktopColumn = null;
  // The same, by the stack's node: a stack a component draws later (inside
  // an inspector's row, say) still finds its column.
  const desktopColumnStacks = new WeakMap();
  // A column's outermost navigation stack: the first, depth first.
  function columnRootStack(node, depth = 0) {
    if (!node || depth > 16) return null;
    if (node.k === "hostView" && node.view === "navstack") return node;
    for (const child of node.ch || []) {
      const found = columnRootStack(child, depth + 1);
      if (found) return found;
    }
    return null;
  }

  function NavSplit({ dark, kids, nodes, preferredPane, compactTick, edit, sidebarWidth, contentWidth, visibility }) {
    // `preferredCompactColumn`: the compact presentation starts on the
    // guest's preferred column and reports pane changes back so the app's
    // binding tracks ("compact:<column>" on the navsplit's event channel).
    // Two-column splits (sidebar + detail, no content child) have one fewer
    // pane; the preferred column clamps into range.
    const paneCount = kids.length;
    const paneNames = paneCount === 2 ? ["sidebar", "detail"] : ["sidebar", "content", "detail"];
    const lastPane = paneCount - 1;
    const [pane, setPaneState] = R.useState(Math.min(preferredPane ?? 0, lastPane));
    const setPane = (next) => {
      // ":back" when the pane went back: the guest clears the selections
      // past it, as SwiftUI's compact split does.
      if (edit) sendEvent(edit, "compact:" + paneNames[next] + (next < pane ? ":back" : ""));
      setPaneState(next);
    };
    // The guest asks to advance when a column's List selection changes (a
    // row tap or a programmatic selection) — SwiftUI's phone behavior.
    const lastTick = R.useRef(compactTick);
    R.useEffect(() => {
      if (compactTick !== lastTick.current) {
        lastTick.current = compactTick;
        if (preferredPane != null) setPaneState(Math.min(preferredPane, lastPane));
      }
    }, [compactTick]);
    const compact = window.innerWidth < 700;
    // The sidebar toggle (regular width): hidden is `.detailOnly`, and the
    // app's `columnVisibility` binding follows ("visibility:<name>").
    const [collapsed, setCollapsed] = R.useState(visibility === "detailOnly");
    R.useEffect(() => { setCollapsed(visibility === "detailOnly"); }, [visibility]);
    const toggleSidebar = () => {
      const next = !collapsed;
      setCollapsed(next);
      if (edit) sendEvent(edit, `visibility:${next ? "detailOnly" : "all"}`);
    };
    const desk = (name, index, toggle) => h(DesktopColumn, { key: name, node: nodes[index], column: name, toggle });
    const divider = (k) => h("div", {
      key: k,
      style: { width: 1, flex: "none", alignSelf: "stretch", background: dark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.12)" },
    });
    const column = (k, width, kid, background, extra) => h("div", {
      key: k,
      ...extra,
      style: {
        width, flex: width == null ? 1 : "none",
        minWidth: width == null ? 0 : undefined,
        display: "flex", flexDirection: "column", minHeight: 0,
        // A content-sized column root sits in the middle (SwiftUI centres a
        // detail view that is not greedy); greedy roots still stretch.
        alignItems: "center", justifyContent: "center",
        alignSelf: "stretch", background,
      },
    }, kid);
    const sidebarBg = dark ? "rgba(30,30,32,0.94)" : "rgba(247,247,247,0.94)";
    if (!compact) {
      // The Mac's sidebar: a panel floating 8pt inside the window, rounded,
      // a shade apart from the window it sits on, no divider beside it.
      const floating = (k, width, kid) => h("div", {
        key: k,
        style: {
          width, flex: "none", display: "flex", flexDirection: "column", minHeight: 0, alignSelf: "stretch",
          margin: "8px 0 8px 8px", borderRadius: 14, overflow: "hidden", boxSizing: "border-box",
          background: dark ? MAC_DARK_SIDEBAR : "rgba(246,246,246,0.96)",
          border: `1px solid ${dark ? "rgba(255,255,255,0.09)" : "rgba(0,0,0,0.08)"}`,
        },
      }, kid);
      const page = dark ? MAC_DARK_PAGE : undefined;
      // `columnVisibility` at regular width: `.detailOnly` shows the detail
      // alone, `.doubleColumn` drops a three-column split's sidebar; `.all`
      // / automatic show every column. The sidebar's toggle (the Mac's) sits
      // in the bar at the top of the sidebar, or of the detail while the
      // sidebar is hidden.
      const detailOnly = collapsed;
      const hideSidebar = detailOnly || (visibility === "doubleColumn" && paneCount === 3);
      const row = { display: "flex", flexDirection: "row", flex: 1, width: "100%", minHeight: 0, alignSelf: "stretch" };
      if (paneCount === 2) {
        return h("div", { style: { ...row, background: page } },
          hideSidebar ? null : floating("sidebar", sidebarWidth, desk("sidebar", 0, toggleSidebar)),
          column("detail", null, desk("detail", 1, hideSidebar ? toggleSidebar : null), page));
      }
      return h("div", { style: { ...row, background: page } },
        hideSidebar ? null : floating("sidebar", sidebarWidth, desk("sidebar", 0, toggleSidebar)),
        detailOnly ? null : column("content", contentWidth, desk("content", 1, hideSidebar ? toggleSidebar : null), page),
        detailOnly ? null : divider("d1"),
        column("detail", null, desk("detail", 2, detailOnly ? toggleSidebar : null), page));
    }
    // Compact: pane 0 = sidebar, 1 = content, 2 = detail. The guest advances
    // the pane on selection changes; Back retreats — drawn in the pane's
    // own navigation bar when it has one (a `SplitBackBar` row otherwise).
    // A compact pane sits on its content's ground, as iOS's do: an
    // inset-grouped list's or a Form's grouped grey, the page's white (or
    // black) behind anything else (a conversation).
    return h(CompactPane, { key: `pane${pane}`, pane, node: nodes[pane], background: paneGround(nodes[pane], dark),
      onBack: pane > 0 ? () => setPane(pane - 1) : null, dark });
  }

  // A column at regular width, rendered here (not the eagerly rendered kid)
  // so the navigation stack at its root sees which column it is.
  function DesktopColumn({ node, column, toggle }) {
    if (!node) return null;
    const previous = currentDesktopColumn;
    currentDesktopColumn = { column, toggle, taken: false, node };
    const stack = columnRootStack(node);
    if (stack) desktopColumnStacks.set(stack, currentDesktopColumn);
    // The sidebar's lists are the sidebar's (as the split's first child is
    // when rendered in place).
    if (column === "sidebar") inSidebar++;
    try {
      return render(node, `${column}:${node.k}${node.view || ""}`, "v");
    } finally {
      currentDesktopColumn = previous;
      if (column === "sidebar") inSidebar--;
    }
  }

  function CompactPane({ pane, node, background, onBack, dark }) {
    // Render the pane's node HERE (not the eagerly rendered kid) so its
    // navstack sees the split's back handler while it builds its bar.
    const previous = currentSplitBack;
    currentSplitBack = onBack ? { back: onBack } : null;
    let kid;
    try {
      kid = render(node, `pane${pane}:${node.k}${node.view || ""}`, "v");
    } finally {
      currentSplitBack = previous;
    }
    const rendered = h("div", {
      style: {
        flex: 1, minWidth: 0, display: "flex", flexDirection: "column", minHeight: 0,
        alignSelf: "stretch", width: "100%", background,
      },
    }, kid);
    // React renders `kid` lazily, so whether a navstack claimed the back
    // handler is only known after this render; the fallback row shows when
    // the pane's tree has no navstack root (see navStack).
    const rows = [];
    if (onBack && !paneHasNavStack(kid)) {
      rows.push(h("div", {
        key: "back",
        onClick: onBack,
        style: {
          padding: "10px 14px", color: "var(--iso-tint, #0a84ff)", cursor: "pointer",
          fontSize: 16, flex: "none",
          fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
        },
      }, "‹ Back"));
    }
    rows.push(h(R.Fragment, { key: "pane" }, rendered));
    return h("div", {
      style: { display: "flex", flexDirection: "column", flex: 1, width: "100%", minHeight: 0, alignSelf: "stretch" },
    }, rows);
  }

  // Whether a rendered pane's element tree starts (within a few wrapper
  // levels) with a navstack — its bar can host the split's Back.
  function paneHasNavStack(element) {
    let node = element;
    for (let depth = 0; node && depth < 6; depth++) {
      const props = node.props || {};
      if (props["data-navstack"]) return true;
      const children = props.children;
      if (Array.isArray(children)) node = children.find((c) => c && c.props);
      else node = children && children.props ? children : null;
    }
    return false;
  }

  function navSplit(n, key, kids) {
    const p = n.params || {};
    const preferred = p.columns === "2"
      ? { sidebar: 0, content: 0, detail: 1 }[p.compact]
      : { sidebar: 0, content: 1, detail: 2 }[p.compact];
    return h(NavSplit, {
      key, dark: p.dark === "1", kids, nodes: n.ch || [],
      preferredPane: preferred, compactTick: p.compactTick, edit: n.edit, visibility: p.visibility,
      // `.navigationSplitViewColumnWidth` hints (sidebarWidth/contentWidth).
      sidebarWidth: Number(p.sidebarWidth) || 240,
      contentWidth: Number(p.contentWidth) || 340,
    });
  }

  // Pointer-drag state for the `map` host view (one pointer pans at a time).
  const mapDrag = { active: false, x: 0, y: 0 };

  // A scroll pinned to its bottom edge (`.defaultScrollAnchor(.bottom)`):
  // GeometryReader measurement: observe the wrapper div's border-box and
  // send each size the host lays out to the guest (deduped per element; a
  // same-size re-report after a remount is harmless — the guest's rebuild is
  // identical, the patch is empty, and the observer quiesces). Sizes are CSS
  // pixels — the same logical points the guest's canvas size uses.
  // `ViewThatFits`: the box's children are the candidates; it shows the
  // first whose ideal (max-content) size fits along the axes given ("h",
  // "v", "hv"), else the last, and is that view's size, as SwiftUI's is.
  // What it is offered is read from its parent: the parent's content box
  // (a column, a frame's box), less its siblings and gaps along a row's
  // axis. Before each paint, and whenever the parent or the shown view
  // changes size, each candidate but the last is measured at its ideal
  // size; the chosen one's slot is `display: contents` (it lays out as the
  // box's own child), the others' `display: none`.
  function FitsBox({ divProps, axes, parentAxis, grows, children }) {
    const ref = R.useRef(null);
    const kids = R.Children.toArray(children);
    const [chosen, setChosen] = R.useState(kids.length - 1);
    const horizontal = axes.includes("h"), vertical = axes.includes("v");
    R.useLayoutEffect(() => {
      const box = ref.current;
      const parent = box && box.parentElement;
      if (!box || !parent) return undefined;
      const offered = () => {
        const cs = getComputedStyle(parent);
        let width = parent.clientWidth - parseFloat(cs.paddingLeft || 0) - parseFloat(cs.paddingRight || 0);
        let height = parent.clientHeight - parseFloat(cs.paddingTop || 0) - parseFloat(cs.paddingBottom || 0);
        const others = [...parent.children].filter((c) => c !== box && getComputedStyle(c).position !== "absolute");
        if (parentAxis === "h") {
          width -= others.reduce((sum, c) => sum + c.getBoundingClientRect().width, 0) + (parseFloat(cs.columnGap) || 0) * others.length;
        } else if (parentAxis === "v") {
          height -= others.reduce((sum, c) => sum + c.getBoundingClientRect().height, 0) + (parseFloat(cs.rowGap) || 0) * others.length;
        }
        return { width, height };
      };
      const choose = () => {
        const { width, height } = offered();
        const slots = box.children;
        let pick = slots.length - 1;
        for (let i = 0; i < slots.length - 1; i++) {
          const slot = slots[i];
          const saved = slot.style.cssText;
          slot.style.cssText = "display:flex;flex-direction:column;position:absolute;visibility:hidden;pointer-events:none;left:0;top:0;"
            + (horizontal ? "width:max-content;" : `width:${width}px;`) + (vertical ? "height:max-content;" : "");
          const r = slot.getBoundingClientRect();
          slot.style.cssText = saved;
          if ((!horizontal || r.width <= width + 0.5) && (!vertical || r.height <= height + 0.5)) { pick = i; break; }
        }
        setChosen((was) => (was === pick ? was : pick));
      };
      choose();
      const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(() => choose());
      if (observer) {
        observer.observe(parent);
        for (const slot of box.children) if (slot.firstElementChild) observer.observe(slot.firstElementChild);
      }
      return () => { if (observer) observer.disconnect(); };
    });
    const shown = Math.min(chosen, kids.length - 1);
    const style = { ...divProps.style, position: divProps.style.position || "relative" };
    // Within what it is offered (a carousel chosen is no wider), and greedy
    // as the view shown is (render's rules for a greedy node).
    if (horizontal && style.maxWidth == null) style.maxWidth = "100%";
    const [growW, growH] = (grows || [])[shown] || [false, false];
    if ((parentAxis === "v" && growH) || (parentAxis === "h" && growW)) { style.flexGrow = 1; style.minHeight = 0; style.minWidth = 0; }
    if ((parentAxis === "v" && growW) || (parentAxis === "h" && growH)) style.alignSelf = "stretch";
    if (parentAxis === "z") { if (growW) style.width = "100%"; if (growH) style.height = "100%"; }
    return h("div", { ...divProps, ref, style }, kids.map((kid, i) =>
      h("div", { key: `fits${i}`, "data-iso-fits": i === shown ? "shown" : "", style: { display: i === shown ? "contents" : "none" } }, kid)));
  }

  // An overlay's layer whose view floats above the screen's chrome (an
  // alignment guide moved it out of the box: a menu floated above a
  // composer). The bars are layers above the content, which nothing inside
  // the content can rise past, so the view is drawn in a layer of its own at
  // the root (as a sheet at regular width is), fixed at the overlay's place:
  // an empty anchor where the layer would be follows the page as it lays
  // out, resizes or scrolls. Its own box takes no pointer events; the view
  // takes them (above the bars, as a context menu does), below a sheet.
  function FloatingLayer({ alignItems, justifyContent, growW, growH, children }) {
    const anchor = R.useRef(null);
    const [rect, setRect] = R.useState(null);
    R.useLayoutEffect(() => {
      const el = anchor.current;
      if (!el) return undefined;
      let frame = 0;
      const place = () => {
        const r = el.getBoundingClientRect();
        setRect((was) => (was && was.left === r.left && was.top === r.top && was.width === r.width && was.height === r.height)
          ? was : { left: r.left, top: r.top, width: r.width, height: r.height });
      };
      place();
      const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(place);
      if (observer) observer.observe(el);
      const moved = () => { cancelAnimationFrame(frame); frame = requestAnimationFrame(place); };
      window.addEventListener("resize", moved);
      window.addEventListener("scroll", moved, true);
      return () => {
        if (observer) observer.disconnect();
        cancelAnimationFrame(frame);
        window.removeEventListener("resize", moved);
        window.removeEventListener("scroll", moved, true);
      };
    }, []);
    return h(R.Fragment, null,
      h("div", { ref: anchor, style: { position: "absolute", inset: 0, pointerEvents: "none", visibility: "hidden" } }),
      rect ? window.ReactDOM.createPortal(h("div", {
        style: { position: "fixed", left: rect.left, top: rect.top, width: rect.width, height: rect.height, zIndex: 10,
                 display: "flex", alignItems, justifyContent, pointerEvents: "none" },
      }, h("div", {
        style: { pointerEvents: "auto", display: "flex", flexDirection: "column", minWidth: 0, minHeight: 0,
                 // Offered the box's size, as in place: a greedy view, or
                 // one capped by `.frame(maxWidth:)`, takes it (up to its
                 // cap) rather than its content's.
                 width: growW ? "100%" : undefined, height: growH ? "100%" : undefined,
                 alignItems: justifyContent },
      }, children)), container) : null);
  }

  function GeometryBox({ divProps, geoId, children }) {
    const ref = R.useRef(null);
    const lastSent = R.useRef("");
    R.useLayoutEffect(() => {
      const el = ref.current;
      if (!el) return undefined;
      const edge = el.querySelector("[data-edge-scroll]");
      const report = () => {
        let w = el.clientWidth;
        let h2 = el.clientHeight;
        if (edge) {
          // The box holds the screen's edge scroll: what the reader
          // measures is the region between the bars (the safe area), as
          // SwiftUI reports it, not the scroll's full extent.
          const cs = getComputedStyle(edge);
          w = edge.clientWidth - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0);
          h2 = edge.clientHeight - (parseFloat(cs.paddingTop) || 0) - (parseFloat(cs.paddingBottom) || 0);
        }
        w = Math.round(w);
        h2 = Math.round(h2);
        if (w <= 0 || h2 <= 0) return;
        // And where it is in the window, for `frame(in: .global)`: measured
        // when it or the window changes size (a phone's keyboard moves the
        // visual viewport), not as a scroll moves it, so a reader in a
        // scrolled list is not rebuilt on every frame of a scroll.
        const place = el.getBoundingClientRect();
        const value = `${w}x${h2}@${Math.round(place.left)},${Math.round(place.top)}`;
        if (lastSent.current === value) return;
        lastSent.current = value;
        sendEvent(geoId, value);
      };
      report();
      const observer = new ResizeObserver(report);
      if (edge) observer.observe(edge);
      observer.observe(el);
      window.addEventListener("resize", report);
      if (window.visualViewport) window.visualViewport.addEventListener("resize", report);
      return () => {
        observer.disconnect();
        window.removeEventListener("resize", report);
        if (window.visualViewport) window.visualViewport.removeEventListener("resize", report);
      };
    }, [geoId]);
    return h("div", { ...divProps, ref }, children);
  }

  // starts at the newest content and follows growth while the user is at the
  // bottom; scrolling up unpins until they return (within a small slop).
  // Edge insets (docs/renderer_layers.md, "bars"): a navigation bar and a
  // `.safeAreaInset` bar are translucent chrome pinned to the edges of the
  // screen they belong to, and the screen's outermost vertical scroll flows
  // beneath them with content insets — the iOS shape — so its content can
  // always reach the top and bottom. The insets travel as CSS variables
  // (`--iso-inset-top/bottom`) from the chrome's container to the scroll,
  // which consumes them as padding and zeroes them for its descendants.
  // Content that is not a scroll is simply laid out inside the insets.
  // The scroll-edge frost's fade: whole under the status bar and the top of
  // the bar, then easing to nothing at the bar's bottom edge.
  const FROST_MASK = "linear-gradient(to bottom, rgba(0,0,0,1) 0%, rgba(0,0,0,0.85) 45%, rgba(0,0,0,0.45) 75%, rgba(0,0,0,0) 100%)";
  const BAR_BACKGROUND = (dark) => dark ? "rgba(28,28,30,0.82)" : "rgba(249,249,249,0.82)";
  // Apple's grouped palette (systemGroupedBackground,
  // secondarySystemGroupedBackground, separator).
  const GROUPED_BACKGROUND = (dark) => dark ? (isDesktop() ? MAC_DARK_PAGE : "#000000") : "#f2f2f7";
  // The desktop's dark window (the Mac's grey, not the iPhone's black) and
  // its floating sidebar panel, a shade darker.
  const MAC_DARK_PAGE = "#232325";
  const MAC_DARK_SIDEBAR = "#1b1b1d";
  // The grounds the guest names ("fillName"), in the desktop's dark palette:
  // the Mac's grey where the iPhone's dark is black, and cells a shade up.
  const MAC_DARK_FILLS = {
    groupedBackground: MAC_DARK_PAGE, barBackground: MAC_DARK_PAGE, secondaryBackground: "#2e2e30",
    // A sheet is the window's grey, its groups a step lighter (as the
    // Mac's Form sheets are).
    elevatedGroupedBackground: MAC_DARK_PAGE, elevatedSecondaryBackground: "#2b2b2d",
  };
  function fillCSS(n) { return namedFillCSS(n.params && n.params.fillName, n.fill); }
  function namedFillCSS(name, color) {
    // A grouped row's fill in the Mac's sidebar, which has none (an app's
    // own row background puts it under its highlight).
    if (name === "secondaryBackground" && inSidebar && isDesktop()) return "transparent";
    if (name && isDesktop() && pageDark() && MAC_DARK_FILLS[name]) return MAC_DARK_FILLS[name];
    // A sheet's grounds are the sheet's to say (a floating sheet's glass
    // shows through them).
    if (name === "elevatedGroupedBackground") return `var(--iso-sheet-grouped-bg, ${rgba(color)})`;
    if (name === "elevatedSecondaryBackground") return `var(--iso-sheet-cell-bg, ${rgba(color)})`;
    return rgba(color);
  }
  const CELL_BACKGROUND = (dark) => dark ? (isDesktop() ? "#2e2e30" : "#1c1c1e") : "#ffffff";
  const SEPARATOR = (dark) => dark ? "rgba(84,84,88,0.65)" : "rgba(60,60,67,0.29)";
  const pageDark = () => document.documentElement.dataset.theme === "dark"
    || (!!window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
  // The web is a phone when narrow and a desktop when wide: narrow canvases
  // take the iOS shapes (large titles, 44pt bars, inset-grouped lists,
  // bottom sheets), wide ones the macOS shapes (an inline title in one
  // 52px toolbar row, borderless bar buttons, the sidebar list style,
  // content-sized sheets).
  const isDesktop = () => window.innerWidth >= 700;
  // The Mac's type ramp (points, as its text styles are), for a page as wide
  // as the Mac's two columns: the desktop web is the Mac's shape, as a phone's
  // width is the iPhone's, whose sizes the guest sends. A text's own size
  // (`.system(size:)`, no style) stays as given.
  const MAC_TEXT_SIZES = { largeTitle: 26, title: 22, title2: 17, title3: 15, headline: 13, body: 13,
    callout: 12, subheadline: 11, footnote: 10, caption: 10, caption2: 10 };
  function textSize(n) {
    const style = n.params && n.params.textStyle;
    return isDesktop() && style && MAC_TEXT_SIZES[style] ? MAC_TEXT_SIZES[style] : n.size;
  }
  // The Mac's headline is bold where the iPhone's is semibold.
  function textWeight(n) {
    return isDesktop() && n.params && n.params.textStyle === "headline" && n.weight === 600 ? 700 : n.weight;
  }
  // How many split-view sidebar columns enclose the rows being rendered.
  let inSidebar = 0;
  // Document scrolling (a phone-width page, opted in with `documentScroll`):
  // the screen's edge scroll is the page's own scroll, as a web page's is —
  // the browser scrolls the document (its bars collapse, content runs under
  // them and behind the keyboard), and the screen's chrome is fixed over it.
  // Presentations (sheets) keep scrolling inside themselves.
  let presentationDepth = 0;
  const docScroll = () => documentScroll && !isDesktop() && presentationDepth === 0;
  // Where each document-scrolled screen was, by its scroll's identity, so
  // moving between screens (they share the page's one scroll) comes back.
  const documentScrollPositions = new Map();
  // The list idiom the rows being rendered belong to ("insetGrouped" while
  // a compact list's rows render, as on an iPhone; "sidebar" in a wide
  // split view's sidebar column; plain rows otherwise).
  let currentListStyle = null;
  // `.listRowSeparator(.hidden)`: no lines between the rows of this list.
  let currentListSeparators = true;
  // `\.defaultMinListRowHeight` on this list when it is not the platform's
  // 44 (its "minRowHeight"): the least a row is tall.
  let currentListMinRowHeight = null;
  const INSET_TOP = "var(--iso-inset-top, 0px)";
  // The top safe area a pinned bar reaches into: the screen's (the status
  // bar), except in a sheet, whose top edge is below it.
  const SAFE_TOP = "var(--iso-safe-top, env(safe-area-inset-top, 0px))";
  const INSET_BOTTOM = "var(--iso-inset-bottom, 0px)";
  const edgeScrolls = new WeakSet();
  // Custom properties resolve on the element that declares them, so a box
  // that pads itself by the insets zeroes them for its descendants one
  // level down (a box-less wrapper).
  const insetsEnd = (key, kids) => h("div", {
    key, style: { display: "contents", "--iso-inset-top": "0px", "--iso-inset-bottom": "0px" },
  }, kids);
  // The outermost vertical scroll a screen's content reaches through plain
  // wrappers (boxes, single-child columns, the content side of an inset
  // stack), or null when the content is not a scroll.
  function edgeScroll(n) {
    let node = n;
    // (Deep enough for a screen's modifiers: see ComposeRenderer's.)
    for (let depth = 0; node && depth < 32; depth++) {
      if (node.k === "scroll") return node.axis === "h" ? null : node;
      const p = node.params || {};
      // `.background` / `.overlay` layers ride alongside the content.
      const ch = (node.ch || []).filter((c) => !(c.params && c.params.layer));
      if (node.k === "stack" && p.inset) { node = ch[p.inset === "top" ? 1 : 0]; continue; }
      // A ZStack of a backdrop (a colour or shape filling the screen) and
      // the content: the backdrop sits under the chrome with the rest.
      if (node.k === "stack" && node.axis === "z") {
        const content = ch.filter((c) => c.k !== "shape" && c.k !== "gradient");
        if (content.length !== 1) return null;
        node = content[0];
        continue;
      }
      if (node.k === "box" || (node.k === "stack" && node.axis === "v")) {
        if (ch.length !== 1) return null;
        node = ch[0];
        continue;
      }
      return null;
    }
    return null;
  }
  // Whether a navstack's chrome is only the 44pt bar (no large title, no
  // search field): then the bar pins over the content.
  function navStackBarOnly(n) {
    const p = n.params || {};
    return (p.displayMode === "inline" || !p.title) && (p.searchPrompt == null || p.searchPrompt === "");
  }
  // The content side of pinned chrome: fills the container; unless its
  // content is an edge scroll (which takes the insets as padding), the
  // insets become the content's own padding.
  function insetContent(key, kids, hasEdgeScroll, belowTopChrome) {
    const style = {
      display: "flex", flexDirection: "column", flex: 1, minHeight: 0, minWidth: 0,
      alignSelf: "stretch", width: "100%", position: "relative", boxSizing: "border-box",
      // Chrome at the top took the status bar's safe area.
      ...(belowTopChrome ? { "--iso-safe-top": "0px" } : {}),
    };
    if (!hasEdgeScroll) {
      style.paddingTop = INSET_TOP;
      style.paddingBottom = INSET_BOTTOM;
      return h("div", { key, style }, insetsEnd("insets-end", kids));
    }
    return h("div", { key, style }, kids);
  }
  // `.safeAreaInset(edge: .bottom/.top)`: the inset is chrome pinned at
  // that edge (translucent, extending into the device's safe area); its
  // measured height is the inset the content beneath it flows under.
  function InsetStack({ n, style, kids, edge, hasEdgeScroll, fixed }) {
    const ref = R.useRef(null);
    const barRef = R.useRef(null);
    R.useLayoutEffect(() => {
      const container = ref.current, bar = barRef.current;
      // Document-scrolled, the bar is in the page's flow (sticky): no inset.
      if (!container || !bar || fixed) return undefined;
      const name = edge === "top" ? "--iso-inset-top" : "--iso-inset-bottom";
      const apply = () => {
        container.style.setProperty(name, `${bar.getBoundingClientRect().height}px`);
        // The scroll's inset changed without the scroll or its rows changing
        // size (the keyboard came up under a composer): a scroll pinned to
        // its end takes the end again, after the new inset.
        window.dispatchEvent(new Event("iso-insets"));
      };
      apply();
      if (typeof ResizeObserver === "undefined") return undefined;
      const observer = new ResizeObserver(apply);
      // Its border box: the keyboard coming up grows the bar's bottom padding
      // (it sits on the keyboard), which a content-box observer never sees,
      // and the scroll's inset stayed short of the keyboard.
      observer.observe(bar, { box: "border-box" });
      return () => observer.disconnect();
    }, [edge, fixed]);
    const contentIndex = edge === "top" ? 1 : 0;
    const insetIndex = edge === "top" ? 0 : 1;
    const bar = h("div", {
      key: "inset",
      ref: barRef,
      ...(fixed ? { "data-iso-inset-bar": edge } : {}),
      style: {
        // On a document-scrolled page the bar is in the page's flow, after
        // (or before) the content, and sticks to the viewport's edge as the
        // page scrolls; at the page's end it rests there, and a focused
        // field in it is scrolled above the keyboard by the browser itself.
        position: fixed ? "sticky" : "absolute", left: 0, right: 0, zIndex: 5,
        [edge === "top" ? "top" : "bottom"]: 0,
        display: "flex", flexDirection: "column", alignItems: "stretch",
        boxSizing: "border-box",
        // The bottom one sits on the keyboard when it is up (the surface
        // pads the keyboard's height; this stack reaches down into it).
        [edge === "top" ? "paddingTop" : "paddingBottom"]: edge === "top"
          ? SAFE_TOP
          : "calc(var(--iso-keyboard, 0px) + var(--iso-safe-bottom, env(safe-area-inset-bottom, 0px)))",
        // No fill of its own: as on iOS, the inset's content draws what it
        // wants (a composer pill), and the scroll shows through around it.
      },
    }, kids[insetIndex]);
    if (fixed) {
      // As tall as the content plus the bar (not the viewport): the page
      // scrolls through it, with the bar stuck to the viewport's edge. At
      // least the viewport's height, so a short screen's bar still sits at
      // the bottom.
      const content = h("div", { key: "content", style: { display: "flex", flexDirection: "column", flex: "1 0 auto", minWidth: 0, width: "100%", "--iso-inset-bottom": "0px" } }, kids[contentIndex]);
      return h("div", {
        ref,
        style: {
          ...style, flex: "none", height: "auto", minHeight: "100%", display: "flex", flexDirection: "column",
          position: "relative", minWidth: 0, alignSelf: "stretch",
        },
      }, edge === "top" ? [bar, content] : [content, bar]);
    }
    return h("div", {
      ref,
      style: {
        ...style, display: "flex", flexDirection: "column", position: "relative", minHeight: 0, minWidth: 0,
        ...(edge === "bottom" ? { marginBottom: "calc(-1 * var(--iso-keyboard, 0px))" } : {}),
      },
    }, insetContent("content", kids[contentIndex], hasEdgeScroll, edge === "top"), bar);
  }

  // A document-scrolled page's visible bottom: the window's, or the top of
  // a bottom `.safeAreaInset` bar stuck over it.
  function documentVisibleBottom() {
    let bottom = window.innerHeight;
    for (const bar of document.querySelectorAll('[data-iso-inset-bar="bottom"]')) {
      const r = bar.getBoundingClientRect();
      if (r.height > 0) bottom = Math.min(bottom, r.top);
    }
    return bottom;
  }

  // `ScrollViewProxy.scrollTo(id, anchor:)`: the core sends the latest
  // request ("id|tick|anchor") to every scroll; the one holding a view with
  // that id brings it to the anchor, once per request, after the render
  // that carries it has laid out.
  function applyScrollRequest(el, request, applied, doc) {
    if (!el || !request) return;
    const [target, tick, anchor] = request.split("|");
    if (applied.current === tick) return;
    const escaped = window.CSS && CSS.escape ? CSS.escape(target) : target.replace(/"/g, '\\"');
    const node = el.querySelector(`[data-vid="${escaped}"]`);
    if (!node) return;
    applied.current = tick;
    // Measured against what is visible: inside the scroll padding the
    // chrome over the scroll reserves (a bar, the composer), as iOS measures
    // inside the content insets.
    const cs = getComputedStyle(el);
    // A document-scrolled screen is measured against the window.
    // Its bottom bar (a composer) is in the page's flow, not an inset: what
    // is visible ends where the bar begins.
    const outer = doc ? { top: 0, bottom: documentVisibleBottom() } : el.getBoundingClientRect();
    const box = { top: outer.top + (parseFloat(cs.scrollPaddingTop) || 0), bottom: outer.bottom - (parseFloat(cs.scrollPaddingBottom) || 0) };
    box.height = box.bottom - box.top;
    const r = node.getBoundingClientRect();
    let delta;
    if (anchor === "bottom") delta = r.bottom - box.bottom;
    else if (anchor === "top") delta = r.top - box.top;
    else if (anchor === "center") delta = (r.top + r.height / 2) - (box.top + box.height / 2);
    else delta = r.top < box.top ? r.top - box.top : (r.bottom > box.bottom ? r.bottom - box.bottom : 0);
    if (doc) window.scrollBy(0, delta);
    else el.scrollTop += delta;
  }

  // A lazy List: report the rows on screen ("first,last" among the list's
  // cells) after each render and as it scrolls, so the guest builds the
  // rows around them.
  // `rows` is the row count of the build these cells came from, echoed back
  // so the guest can tell a report about rows it has since replaced (a
  // thread's loading rows, reported after its transcript arrived).
  function useListWindow(ref, windowId, doc, rows) {
    const reported = R.useRef("");
    const pending = R.useRef(false);
    const rowsRef = R.useRef(rows);
    rowsRef.current = rows;
    const report = () => {
      const el = ref.current;
      if (!el || !windowId) return;
      const cells = [...el.querySelectorAll("[data-iso-cell]")].filter((c) => c.closest("[data-iso-scroll]") === el);
      if (!cells.length) return;
      const box = doc ? { top: 0, bottom: window.innerHeight } : el.getBoundingClientRect();
      // Binary search: the first cell reaching below the top, the last
      // starting above the bottom.
      const firstBelow = (y) => {
        let lo = 0, hi = cells.length - 1, found = cells.length - 1;
        while (lo <= hi) {
          const mid = (lo + hi) >> 1;
          if (cells[mid].getBoundingClientRect().bottom > y) { found = mid; hi = mid - 1; } else lo = mid + 1;
        }
        return found;
      };
      const first = firstBelow(box.top);
      const last = Math.max(first, firstBelow(box.bottom));
      const value = rowsRef.current != null ? `${first},${last},${rowsRef.current}` : `${first},${last}`;
      if (value !== reported.current) { reported.current = value; sendEvent(windowId, value); }
    };
    R.useLayoutEffect(report);
    return () => {
      if (pending.current) return;
      pending.current = true;
      requestAnimationFrame(() => { pending.current = false; report(); });
    };
  }

  // `onScrollPhaseChange`: a browser says that a scroll moved, not why, so
  // the phase is read from the reader's input around it. A scroll while a
  // finger, the pointer (the scroll bar), the wheel or a key drives it is
  // "interacting"; one after the finger lifts is the coast ("decelerating");
  // quiet for 150 ms (or `scrollend`) with nothing held is "idle". A scroll
  // with none of those is the renderer's own (a pin to the bottom, a
  // `scrollTo`, both instant) and is not reported, as SwiftUI reports none
  // for a scroll that is not animated.
  function useScrollPhase(ref, phaseId, doc) {
    R.useEffect(() => {
      const el = ref.current;
      if (!phaseId || !el) return undefined;
      const target = doc ? window : el;
      let phase = "idle", touching = false, pressing = false, wheelAt = -1e9, keyAt = -1e9, timer = 0;
      const report = (next) => {
        if (next === phase) return;
        phase = next;
        sendEvent(phaseId, next);
      };
      const settle = () => {
        clearTimeout(timer);
        timer = 0;
        if (!touching && !pressing) report("idle");
      };
      const onScroll = () => {
        const now = performance.now();
        if (touching || pressing || now - wheelAt < 200 || now - keyAt < 600) report("interacting");
        else if (phase === "interacting" || phase === "decelerating") report("decelerating");
        else return;
        clearTimeout(timer);
        timer = setTimeout(settle, 150);
      };
      const onTouchStart = () => { touching = true; };
      const onTouchEnd = (e) => {
        if (e.touches && e.touches.length) return;
        touching = false;
        clearTimeout(timer);
        timer = setTimeout(settle, 150);
      };
      // The scroll bar (or the scroll's own empty area) under the pointer.
      const onPointerDown = (e) => { if (e.pointerType === "mouse" && e.target === el) pressing = true; };
      const onPointerUp = () => {
        if (!pressing) return;
        pressing = false;
        clearTimeout(timer);
        timer = setTimeout(settle, 150);
      };
      const onWheel = () => { wheelAt = performance.now(); };
      const onKey = (e) => { if (doc || el.contains(e.target)) keyAt = performance.now(); };
      const onScrollEnd = () => { if (!touching && !pressing && phase !== "idle") settle(); };
      target.addEventListener("scroll", onScroll, { passive: true });
      target.addEventListener("scrollend", onScrollEnd);
      el.addEventListener("touchstart", onTouchStart, { passive: true });
      window.addEventListener("touchend", onTouchEnd, { passive: true });
      window.addEventListener("touchcancel", onTouchEnd, { passive: true });
      el.addEventListener("pointerdown", onPointerDown);
      window.addEventListener("pointerup", onPointerUp);
      target.addEventListener("wheel", onWheel, { passive: true });
      window.addEventListener("keydown", onKey);
      return () => {
        clearTimeout(timer);
        target.removeEventListener("scroll", onScroll);
        target.removeEventListener("scrollend", onScrollEnd);
        el.removeEventListener("touchstart", onTouchStart);
        window.removeEventListener("touchend", onTouchEnd);
        window.removeEventListener("touchcancel", onTouchEnd);
        el.removeEventListener("pointerdown", onPointerDown);
        window.removeEventListener("pointerup", onPointerUp);
        target.removeEventListener("wheel", onWheel);
        window.removeEventListener("keydown", onKey);
      };
    }, [phaseId, doc]);
  }

  // A scroll the renderer keeps a hand on: `ScrollViewProxy.scrollTo`
  // requests, a lazy List's window, the page's scroll when it is document-
  // scrolled, and `.defaultScrollAnchor(.bottom)` (a chat log: start at the
  // bottom and stay pinned there as content grows, until the reader scrolls
  // up). One component whatever the anchor, so the anchor changing (AgentUI
  // holds the top for the moment rows are appended, then scrolls down to
  // them) keeps the scroll and its rows rather than building them again.
  function ManagedScroll({ divProps, children, request, windowId, doc, id, bottom, epoch, rows, geometryId, phaseId }) {
    const ref = R.useRef(null);
    useScrollPhase(ref, phaseId, doc);
    // `onScrollGeometryChange`: where the scroll is and how large its
    // content is, reported (in points) as either changes.
    R.useEffect(() => {
      const el = ref.current;
      if (!geometryId || !el) return;
      let reported = "";
      const report = () => {
        const top = doc ? window.scrollY : el.scrollTop;
        const height = doc ? document.documentElement.scrollHeight : el.scrollHeight;
        const viewport = doc ? window.innerHeight : el.clientHeight;
        const value = [doc ? window.scrollX : el.scrollLeft, top, el.scrollWidth, height, el.clientWidth, viewport, 0, 0, 0, 0]
          .map((v) => Number(v).toFixed(1)).join(",");
        if (value !== reported) { reported = value; sendEvent(geometryId, value); }
      };
      const target = doc ? window : el;
      target.addEventListener("scroll", report, { passive: true });
      const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(report);
      if (observer) { observer.observe(el); if (el.firstElementChild) observer.observe(el.firstElementChild); }
      report();
      return () => { target.removeEventListener("scroll", report); if (observer) observer.disconnect(); };
    }, [geometryId, doc]);
    const applied = R.useRef(null);
    const anchored = R.useRef(bottom);
    anchored.current = bottom;
    const pinned = R.useRef(true);
    const last = R.useRef({ top: 0, max: 0 });
    // The list's rows replaced wholesale (another conversation in the same
    // pane): a chat opens at its end, whatever the last one was scrolled to.
    const seenEpoch = R.useRef(epoch);
    if (epoch !== seenEpoch.current) {
      seenEpoch.current = epoch;
      pinned.current = true;
      last.current = { top: 0, max: 0 };
    }
    const pin = () => {
      const el = ref.current;
      if (!el || !anchored.current || !pinned.current) return;
      if (doc) {
        // Safari brings its whole toolbar back when a scroll reaches the
        // page's very end, and with the keyboard up that toolbar is taken
        // out of the viewport: the composer ends a toolbar's height above
        // the keys. While a field is edited the pin stops 2px short of
        // the end (still "at the end" to `track`), which Safari leaves be.
        const active = document.activeElement;
        const editing = !!active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable);
        const page = document.documentElement;
        window.scrollTo(0, editing ? Math.max(0, page.scrollHeight - window.innerHeight - 2) : page.scrollHeight);
      } else el.scrollTop = el.scrollHeight;
    };
    // Only the reader scrolling up lets go of the bottom: content growing
    // between a pin and the scroll event it causes leaves a few pixels
    // below, and content shrinking pulls the scroll up with it — neither
    // is the reader leaving.
    const track = (top, max) => {
      if (top >= max - 4) pinned.current = true;
      else if (top < last.current.top - 1 && max >= last.current.max) pinned.current = false;
      last.current = { top, max };
    };
    // Document-scrolled: the page's scroll is this screen's while it is
    // shown — back where it was (or at the bottom, anchored there), and
    // reporting as the page scrolls.
    R.useLayoutEffect(() => {
      if (!doc) return undefined;
      if (!anchored.current) window.scrollTo(0, documentScrollPositions.get(id) || 0);
      const onScroll = () => {
        documentScrollPositions.set(id, window.scrollY);
        const page = document.documentElement;
        track(window.scrollY, page.scrollHeight - window.innerHeight);
        onWindowScroll();
      };
      window.addEventListener("scroll", onScroll, { passive: true });
      return () => window.removeEventListener("scroll", onScroll);
    }, [doc, id]);
    // The scroll resizing (the soft keyboard, the window) and its content
    // growing without this component re-rendering (a memoized row's own
    // update, a transcript's rows arriving): stay at the bottom through
    // both before the frame is painted, as Messages does. Its children are
    // observed afresh after every commit, as rows come and go.
    const observer = R.useRef(null);
    R.useLayoutEffect(() => {
      applyScrollRequest(ref.current, request, applied, doc);
      pin();
      const el = ref.current, watch = observer.current;
      if (el && watch) for (const child of el.children) watch.observe(child);
    });
    // The rows shown are reported after the pin above has moved the scroll
    // (layout effects run in order): reported before it, a thread opening
    // at its end reported its top — where the loading rows had left the
    // scroll — and the guest built the top, leaving the end as placeholders
    // for a frame.
    const onWindowScroll = useListWindow(ref, windowId, doc, rows);
    // Set up before the first paint, so a list whose rows land in the
    // frames right after it appears is followed from the start.
    R.useLayoutEffect(() => {
      const el = ref.current;
      if (!el) return undefined;
      const watch = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(pin);
      observer.current = watch;
      if (watch) {
        watch.observe(el);
        for (const child of el.children) watch.observe(child);
      }
      const viewport = window.visualViewport;
      if (viewport) viewport.addEventListener("resize", pin);
      window.addEventListener("iso-insets", pin);
      return () => {
        observer.current = null;
        if (watch) watch.disconnect();
        if (viewport) viewport.removeEventListener("resize", pin);
        window.removeEventListener("iso-insets", pin);
      };
    }, [doc]);
    return h("div", {
      ...divProps,
      ref,
      className: bottom ? ((divProps.className || "") + " iso-anchor-bottom").trim() : divProps.className,
      onScroll: (e) => {
        const el = e.currentTarget;
        if (!doc) track(el.scrollTop, el.scrollHeight - el.clientHeight);
        if (divProps.onScroll) divProps.onScroll(e);
        onWindowScroll();
      },
    }, children);
  }

  function hostView(n, props, kids) {
    const p = n.params || {};
    switch (n.view) {
      case "navbar": return navBar(n, kids);
      case "tabbar": return tabBar(n);
      case "search":
        return h(TextInput, { n: { ...n, searchStyle: true, placeholder: p.prompt || "" } });
      case "toggle":
        return h("input", {
          type: "checkbox",
          className: "iso-switch",
          checked: n.v === "1",
          onChange: (e) => sendEvent(n.edit, e.target.checked ? "1" : "0"),
        });
      case "picker":
      case "menu": {
        // A picker in a Form's or a List's row (`formRow`) is drawn as
        // SwiftUI draws it there.
        const inRow = n.view === "picker" && p.formRow === "1";
        if (n.view === "picker" && p.style === "segmented") {
          return h(Segmented, {
            key: props.key, options: n.options || [], selected: Number(n.v) || 0, wide: inRow,
            dark: document.documentElement.dataset.theme === "dark"
              || (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches),
            onSelect: (i) => sendEvent(n.edit, String(i)),
          });
        }
        // A pop-up panel (the platform's menu shape), not a <select>: a
        // Menu's options are its label then its actions; a picker's are
        // its choices with the current one checked.
        const isPicker = n.view === "picker";
        const options = n.options || [];
        const selected = isPicker ? Number(n.v) || 0 : -1;
        const label = isPicker ? (options[selected] || "") : (options[0] || "Menu");
        const items = isPicker
          ? options.map((title, i) => ({ title, checked: i === selected, index: i }))
          : options.slice(1).map((title, i) => ({ title, index: i + 1 }));
        const openIt = (e) => { e.stopPropagation(); showPopMenu(e.currentTarget, items, (i) => sendEvent(n.edit, String(items[i].index))); };
        // A menu picker in a row: its title leading and its value trailing,
        // in the tint with up-and-down chevrons (iOS), or the pop-up button
        // there (the Mac, two columns wide). `.labelsHidden()`: the value
        // alone, where the row starts.
        if (inRow && (!p.style || p.style === "menu")) {
          const title = p.labelsHidden === "1" ? "" : (p.title || "");
          const value = isDesktop()
            ? h("button", { key: "v", type: "button", onClick: openIt,
                style: { display: "inline-flex", alignItems: "center", gap: 6, fontSize: 13, padding: "3px 8px", borderRadius: 6,
                  border: "none", background: "rgba(120,120,128,0.14)", color: "inherit", fontFamily: MENU_FONT, cursor: "pointer" } },
                h("span", { key: "l" }, label), h("span", { key: "c", style: { fontSize: 10, opacity: 0.7 } }, "⌃⌄"))
            : h("button", { key: "v", type: "button", onClick: openIt,
                style: { display: "inline-flex", alignItems: "center", gap: 5, padding: 0, border: "none", background: "none",
                  color: "var(--iso-tint, #007aff)", font: "inherit", cursor: "pointer", minWidth: 0 } },
                h("span", { key: "l", style: { whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" } }, label),
                symbolSVG(h, "chevron.up.chevron.down", 13, "currentColor", 600));
          return h("div", {
            ...props,
            // The row's words, body text (a row's title is not the cell's
            // own text, so nothing above sets its face).
            style: { ...props.style, display: "flex", alignItems: "center", gap: 12, flex: "1 1 auto", alignSelf: "stretch",
              width: "100%", minWidth: 0, fontFamily: SYSTEM_FONT, fontSize: isDesktop() ? (MAC_TEXT_SIZES.body || 13) : 17 },
          }, title ? h("span", { key: "t", style: { flex: "1 1 auto", minWidth: 0 } }, title) : null,
             title ? value : h("span", { key: "w", style: { display: "inline-flex" } }, value));
        }
        // A Menu with a label of the app's own (a symbol in a circle) is that
        // label, as SwiftUI draws it: no chip around it, no chevrons (those
        // are a picker's).
        if (!isPicker && p.labelContent === "1" && kids && kids.length) {
          return h("button", {
            ...props, type: "button", onClick: openIt,
            style: { ...props.style, display: "inline-flex", alignItems: "center", padding: 0, border: "none",
              background: "none", color: "inherit", cursor: "pointer" },
          }, kids[0]);
        }
        return h("button", {
          ...props, type: "button", onClick: openIt,
          style: { ...props.style, display: "inline-flex", alignItems: "center", gap: 6, fontSize: 15, padding: "6px 10px", borderRadius: 10,
            border: "none", background: "rgba(120,120,128,0.14)", color: "inherit", fontFamily: MENU_FONT, cursor: "pointer" },
        }, p.labelContent === "1" && kids && kids.length
          ? [h("span", { key: "l", style: { display: "inline-flex", alignItems: "center" } }, kids[0]),
             h("span", { key: "c", style: { fontSize: 11, opacity: 0.7 } }, "⌃⌄")]
          : [h("span", { key: "l" }, label), h("span", { key: "c", style: { fontSize: 11, opacity: 0.7 } }, "⌃⌄")]);
      }
      case "datepicker":
        props.type = "date";
        props.value = n.v || "";
        props.onChange = (e) => sendEvent(n.edit, e.target.value);
        return h("input", props);
      case "image":
        props.src = /^(https?:|data:|blob:)/.test(n.v) ? n.v : assetBase + n.v;
        props.style = { ...props.style, maxWidth: "100%", objectFit: "contain" };
        return h("img", props);
      case "webview":
        props.src = n.v;
        props.style = { ...props.style, border: "none", width: "100%", height: "100%", flex: 1, alignSelf: "stretch" };
        return h("iframe", props);
      case "codeeditor":
        return h(CodeEditor, { key: props.key, n });
      case "surface": {
        // A page-owned surface: the host mounts its own DOM into this
        // element (`window.isoSurfaceMount(name, element | null, send)`),
        // e.g. the Playground's running build; `send` reports back through
        // the host view's value channel.
        props.style = {
          ...props.style, width: "100%", height: "100%", flex: 1,
          alignSelf: "stretch", position: "relative", overflow: "hidden", display: "flex", flexDirection: "column",
        };
        const name = n.v;
        const send = (value) => sendEvent(n.edit, value);
        props.ref = (el) => { if (window.isoSurfaceMount) window.isoSurfaceMount(name, el, send); };
        return h("div", props);
      }
      case "metal": {
        // A MetalView: a canvas of its own, a surface of the page's Metal
        // executor, drawn each animation frame (metalViews in boot.js).
        props.style = {
          ...props.style, width: "100%", height: "100%", flex: 1,
          alignSelf: "stretch", display: "block",
        };
        if (metalViews) props.ref = (el) => metalViews.attach(el, n.v, (value) => sendEvent(n.edit, value));
        return h("canvas", props);
      }
      case "map": {
        // Real SwiftMap tiles: the wasm module draws into the page canvas,
        // which the boot layer parks inside this element (mapSurface). This
        // element owns the gestures, translated to the same camera-binding
        // commands the self-drawing renderers send ("pan:dx,dy" /
        // "zoom:dy,ax,ay,w,h" — MapSupport.applyGesture).
        props.style = {
          ...props.style, width: "100%", height: "100%", flex: 1,
          alignSelf: "stretch", position: "relative", overflow: "hidden",
          touchAction: "none",
        };
        if (mapSurface) props.ref = (el) => mapSurface.attach(el, n);
        props.onPointerDown = (e) => {
          mapDrag.active = true;
          mapDrag.x = e.clientX;
          mapDrag.y = e.clientY;
          e.currentTarget.setPointerCapture(e.pointerId);
        };
        props.onPointerMove = (e) => {
          if (!mapDrag.active) return;
          sendEvent(n.edit, `pan:${e.clientX - mapDrag.x},${e.clientY - mapDrag.y}`);
          mapDrag.x = e.clientX;
          mapDrag.y = e.clientY;
        };
        props.onPointerUp = () => { mapDrag.active = false; };
        props.onWheel = (e) => {
          const r = e.currentTarget.getBoundingClientRect();
          sendEvent(n.edit,
            `zoom:${e.deltaY},${e.clientX - r.left},${e.clientY - r.top},${r.width},${r.height}`);
        };
        return h("div", props);
      }
      case "video":
        props.src = n.v;
        props.controls = true;
        props.playsInline = true;
        props.style = { ...props.style, width: "100%", background: "#000", objectFit: "contain" };
        return h("video", props);
      default:
        if (n.view && n.view.startsWith("html:")) {
          props.type = n.view.slice(5);
          props.value = n.v || "";
          props.onChange = (e) => sendEvent(n.edit, e.target.value);
          return h("input", props);
        }
        return h("div", props, kids);
    }
  }

  // --- Pop-up menus -------------------------------------------------------
  // One floating panel at a time, appended to the document (so it escapes
  // any clipping ancestor), dismissed by a tap outside or Escape. Items:
  // { title, symbol, destructive, checked }.
  const MENU_FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif";
  let openMenu = null;
  function closePopMenu() {
    if (openMenu) { openMenu.remove(); openMenu = null; }
    document.removeEventListener("pointerdown", onOutsidePointer, true);
    document.removeEventListener("keydown", onMenuKey, true);
  }
  function onOutsidePointer(e) { if (openMenu && !openMenu.contains(e.target)) closePopMenu(); }
  function onMenuKey(e) { if (e.key === "Escape") closePopMenu(); }
  function showPopMenu(anchor, items, onPick) {
    closePopMenu();
    const dark = document.documentElement.dataset.theme === "dark"
      || (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
    const panel = document.createElement("div");
    panel.setAttribute("role", "menu");
    panel.style.cssText = "position:fixed;z-index:60;min-width:200px;max-width:320px;padding:6px 0;border-radius:13px;"
      + "font-family:" + MENU_FONT + ";font-size:15px;overflow:hidden;"
      + (dark ? "background:rgba(44,44,46,0.92);color:#fff;" : "background:rgba(250,250,250,0.92);color:#000;")
      + "backdrop-filter:blur(30px) saturate(180%);-webkit-backdrop-filter:blur(30px) saturate(180%);"
      + "box-shadow:0 8px 40px rgba(0,0,0,0.28),0 0 0 0.5px rgba(0,0,0,0.12);";
    items.forEach((item, i) => {
      const row = document.createElement("div");
      row.setAttribute("role", "menuitem");
      row.style.cssText = "display:flex;align-items:center;gap:10px;padding:10px 16px;cursor:pointer;user-select:none;"
        + (item.destructive ? "color:#ff3b30;" : "")
        + (i > 0 ? (dark ? "border-top:0.5px solid rgba(255,255,255,0.12);" : "border-top:0.5px solid rgba(0,0,0,0.1);") : "");
      const title = document.createElement("span");
      title.style.cssText = "flex:1;";
      title.textContent = item.title;
      row.appendChild(title);
      if (item.checked) { const check = document.createElement("span"); check.textContent = "✓"; check.style.cssText = "font-weight:600;"; row.appendChild(check); }
      else if (item.symbol) { const icon = symbolElement(item.symbol, 18); if (icon) { icon.style.opacity = "0.8"; row.appendChild(icon); } }
      row.onpointerenter = () => { row.style.background = dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)"; };
      row.onpointerleave = () => { row.style.background = ""; };
      row.onclick = (e) => { e.stopPropagation(); closePopMenu(); onPick(i); };
      panel.appendChild(row);
    });
    document.body.appendChild(panel);
    // Below the anchor (or at the pointer), kept on screen.
    const r = anchor.getBoundingClientRect ? anchor.getBoundingClientRect() : { left: anchor.x, right: anchor.x, top: anchor.y, bottom: anchor.y };
    const w = panel.offsetWidth, hgt = panel.offsetHeight;
    let x = Math.min(Math.max(8, r.left), window.innerWidth - w - 8);
    let y = r.bottom + 6;
    if (y + hgt > window.innerHeight - 8) y = Math.max(8, r.top - hgt - 6);
    panel.style.left = x + "px"; panel.style.top = y + "px";
    openMenu = panel;
    setTimeout(() => {
      document.addEventListener("pointerdown", onOutsidePointer, true);
      document.addEventListener("keydown", onMenuKey, true);
    }, 0);
  }
  function symbolGlyph(name) {
    const map = { "trash": "🗑", "pencil": "✎", "archivebox": "🗄", "square.and.pencil": "✎", "tray.and.arrow.up": "⤴", "xmark.circle": "⊗", "doc.on.doc": "⧉", "arrow.clockwise": "↻", "checkmark": "✓" };
    return map[name] || "";
  }
  /// A symbol as a detached SVG element (for the imperative pop-up panel).
  function symbolElement(name, size, color) {
    const entry = SYMBOLS[name];
    if (!entry) return null;
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("width", size); svg.setAttribute("height", size);
    svg.setAttribute("fill", entry.fill ? "currentColor" : "none"); svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", entry.fill ? "1.5" : "2"); svg.setAttribute("stroke-linecap", "round"); svg.setAttribute("stroke-linejoin", "round");
    svg.style.cssText = "display:block;flex-shrink:0;" + (color ? "color:" + color + ";" : "");
    const path = document.createElementNS(ns, "path"); path.setAttribute("d", entry.d); svg.appendChild(path);
    if (entry.inner) { const inner = document.createElementNS(ns, "path"); inner.setAttribute("d", entry.inner); inner.setAttribute("fill", "none"); inner.setAttribute("stroke", "#fff"); inner.setAttribute("stroke-width", "2.2"); svg.appendChild(inner); }
    return svg;
  }
  /// Row actions as encoded by the guest: index␞title␞symbol␞d? per item, ␟ between.
  function decodeRowActions(text) {
    return String(text || "").split("\u001f").filter(Boolean).map((part) => {
      const [index, title, symbol, flag] = part.split("\u001e");
      return { index: Number(index), title, symbol, destructive: flag === "d" };
    });
  }
  /// Long press (450 ms, still) or a secondary click opens the row's menu.
  function attachContextMenu(props, n) {
    const items = decodeRowActions(n.params.ctxitems);
    const open = (x, y) => showPopMenu({ x, y }, items, (i) => sendEvent(n.params.ctxmenu, String(items[i].index)));
    const prevDown = props.onPointerDown, prevUp = props.onPointerUp, prevClick = props.onClick;
    let timer = null, fired = false, startX = 0, startY = 0;
    props.onContextMenu = (e) => { e.preventDefault(); e.stopPropagation(); open(e.clientX, e.clientY); };
    props.onPointerDown = (e) => {
      if (prevDown) prevDown(e);
      if (e.button !== 0) return;
      fired = false; startX = e.clientX; startY = e.clientY;
      timer = setTimeout(() => { fired = true; open(startX, startY + 8); }, 450);
    };
    props.onPointerMove = (e) => { if (timer && (Math.abs(e.clientX - startX) > 8 || Math.abs(e.clientY - startY) > 8)) { clearTimeout(timer); timer = null; } };
    const end = (e) => { if (timer) { clearTimeout(timer); timer = null; } if (prevUp) prevUp(e); };
    props.onPointerUp = end;
    props.onPointerCancel = end;
    props.onClick = (e) => { if (fired) { fired = false; e.stopPropagation(); e.preventDefault(); return; } if (prevClick) prevClick(e); };
    props.style = { ...props.style, WebkitTouchCallout: "none", userSelect: "none" };
  }

  // Swipe actions on a list row: the content slides with a horizontal drag
  // and the buttons show in the space it leaves; a full swipe performs the
  // first one. Rows spring back on release short of halfway.
  function SwipeRow({ n, divProps, children }) {
    const leading = decodeRowActions((n.params || {}).swipeLeading);
    const trailing = decodeRowActions((n.params || {}).swipeTrailing);
    const full = (n.params || {}).swipeFull === "1";
    const [dx, setDx] = R.useState(0);
    const drag = R.useRef({ active: false, x: 0, y: 0, decided: false, horizontal: false });
    const width = 84;
    const perform = (item) => { setDx(0); sendEvent(n.params.swipe, String(item.index)); };
    const onDown = (e) => { if (e.pointerType === "mouse" && e.button !== 0) return; drag.current = { active: true, x: e.clientX, y: e.clientY, decided: false, horizontal: false, base: dx }; };
    const onMove = (e) => {
      const d = drag.current; if (!d.active) return;
      const mx = e.clientX - d.x, my = e.clientY - d.y;
      if (!d.decided) { if (Math.abs(mx) < 6 && Math.abs(my) < 6) return; d.decided = true; d.horizontal = Math.abs(mx) > Math.abs(my); if (d.horizontal) e.currentTarget.setPointerCapture(e.pointerId); }
      if (!d.horizontal) return;
      let next = d.base + mx;
      if (next < 0 && !trailing.length) next = 0;
      if (next > 0 && !leading.length) next = 0;
      setDx(next);
    };
    const onUp = (e) => {
      const d = drag.current; if (!d.active) return; d.active = false;
      const rowWidth = e.currentTarget.getBoundingClientRect().width;
      if (dx < 0 && trailing.length) {
        if (full && -dx > rowWidth * 0.6) { perform(trailing[0]); return; }
        setDx(-dx > width * trailing.length * 0.5 ? -width * trailing.length : 0);
      } else if (dx > 0 && leading.length) {
        if (full && dx > rowWidth * 0.6) { perform(leading[0]); return; }
        setDx(dx > width * leading.length * 0.5 ? width * leading.length : 0);
      } else setDx(0);
    };
    const button = (item, i, side) => h("div", {
      key: side + i,
      onClick: (e) => { e.stopPropagation(); perform(item); },
      style: { width, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 4, color: "#fff", fontFamily: MENU_FONT, fontSize: 13, cursor: "pointer",
        background: item.destructive ? "#ff3b30" : (i === 0 ? (side === "t" ? "#ff9500" : "#34c759") : "#8e8e93") },
    }, [item.symbol ? (symbolSVG(h, item.symbol, 18, "#fff", 400, { verticalAlign: "0" }) || h("span", { key: "g", style: { fontSize: 18 } }, symbolGlyph(item.symbol))) : null, h("span", { key: "t" }, item.title)]);
    // The wrapper is the row in its parent's layout (it takes the node's
    // growth and stretch; content-sized, a row of text and a spacer sat
    // centred in its cell), and the content fills the wrapper.
    const layout = {};
    for (const key of ["flex", "flexGrow", "flexShrink", "flexBasis", "alignSelf", "width", "minWidth", "maxWidth", "gridArea", "gridRow", "gridColumn"]) {
      if (divProps.style[key] !== undefined) layout[key] = divProps.style[key];
    }
    const outer = { ...layout, position: "relative", overflow: "hidden", touchAction: "pan-y", display: "flex", flexDirection: "column", alignItems: "stretch" };
    // The buttons exist only while revealed (a closed row is just its content).
    return h("div", { style: outer, onPointerDown: onDown, onPointerMove: onMove, onPointerUp: onUp, onPointerCancel: onUp },
      dx > 0 && leading.length ? h("div", { key: "l", style: { position: "absolute", left: 0, top: 0, bottom: 0, display: "flex", width: dx } }, leading.map((it, i) => button(it, i, "l"))) : null,
      dx < 0 && trailing.length ? h("div", { key: "r", style: { position: "absolute", right: 0, top: 0, bottom: 0, display: "flex", justifyContent: "flex-end", width: -dx } }, trailing.map((it, i) => button(it, i, "t"))) : null,
      h("div", { key: "c", ...divProps, style: { ...divProps.style, alignSelf: "stretch", flex: "1 1 auto", transform: dx ? `translateX(${dx}px)` : undefined, transition: drag.current.active ? "none" : "transform 0.2s ease-out", // Opaque only while it slides over the buttons: at rest the row is
        // its cell's ground, whatever that is.
        background: divProps.style.background || (dx ? "var(--iso-cell-bg, Canvas)" : undefined) } }, children));
  }

  /// A concatenated Text's spans: `length:flags[:r,g,b,a]` per run, ";"
  /// between (flags ⊂ b i m u s), applied over the text's own style.
  function styledRuns(h, text, encoded) {
    const chars = Array.from(text);
    let at = 0;
    return String(encoded).split(";").map((part, i) => {
      const [len, flags = "", color] = part.split(":");
      const slice = chars.slice(at, at + Number(len)).join("");
      at += Number(len);
      const style = {};
      if (flags.includes("b")) style.fontWeight = 600;
      if (flags.includes("i")) style.fontStyle = "italic";
      if (flags.includes("m")) { style.fontFamily = MONO_FONT; style.fontSize = "0.92em"; }
      const decorations = [flags.includes("u") ? "underline" : "", flags.includes("s") ? "line-through" : ""].filter(Boolean);
      if (decorations.length) style.textDecoration = decorations.join(" ");
      if (color) { const c = color.split(",").map(Number); style.color = `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${c[3] == null ? 1 : c[3]})`; }
      return h("span", { key: i, style }, slice);
    });
  }

  // A request presentation: the browser's own picker (a file input, with
  // `capture` for the camera), answered with the stored files' paths ("" when
  // cancelled). Nothing is drawn.
  function PickerRequest({ n }) {
    // A layout effect: it runs inside the commit, so a commit made during
    // the reader's tap opens the picker while Safari still counts the tap.
    R.useLayoutEffect(() => {
      const p = n.params || {};
      const input = document.createElement("input");
      input.type = "file";
      if (p.accept && p.accept !== "*/*") input.accept = p.accept;
      if (p.multiple === "1") input.multiple = true;
      if (p.request === "camera") input.capture = "environment";
      input.style.display = "none";
      let answered = false;
      const answer = (value) => {
        if (answered) return;
        answered = true;
        input.remove();
        sendEvent(p.result, value);
      };
      input.addEventListener("change", async () => {
        let files = Array.from(input.files || []);
        const max = Number(p.max || 0);
        if (max > 0) files = files.slice(0, max);
        answer((await storeFiles(files)).join("\n"));
      });
      input.addEventListener("cancel", () => answer(""));
      document.body.appendChild(input);
      input.click();
      return () => { if (!answered) input.remove(); };
    }, []);
    return null;
  }

  // The fill of the backdrop a content paints behind itself (a Form's
  // grouped ground: a full-bleed shape under its scroll in a ZStack),
  // through plain wrappers and a navigation stack.
  function backdropFill(start) {
    let node = start;
    for (let depth = 0; node && depth < 32; depth++) {
      const ch = (node.ch || []).filter((c) => !(c.params && c.params.layer));
      if (node.k === "hostView" && node.view === "navstack") { node = ch[0]; continue; }
      if (node.k === "stack" && node.axis === "z") {
        const first = ch[0];
        return first && first.k === "shape" && first.expandH && first.fill ? fillCSS(first) : null;
      }
      if ((node.k === "box" || (node.k === "stack" && node.axis === "v")) && ch.length === 1) { node = ch[0]; continue; }
      return null;
    }
    return null;
  }

  // The ground a compact pane shows behind its content: a backdrop the
  // content draws, a grouped list's grey, else the page's.
  function paneGround(node, dark) {
    const fill = backdropFill(node);
    if (fill) return fill;
    let content = node;
    if (content && content.k === "hostView" && content.view === "navstack") content = (content.ch || [])[0];
    const scroll = edgeScroll(content);
    const p = (scroll && scroll.params) || {};
    if (p.list && p.listStyle !== "plain") return GROUPED_BACKGROUND(dark);
    return dark ? "#000" : "#fff";
  }

  // Whether a presentation's content is a grouped list (through its
  // navigation stack and plain wrappers).
  function sheetHoldsGroupedList(n) {
    let content = (n.ch || [])[0];
    if (content && content.k === "hostView" && content.view === "navstack") content = (content.ch || [])[0];
    const scroll = edgeScroll(content);
    const p = (scroll && scroll.params) || {};
    return !!p.list && p.listStyle !== "plain";
  }

  function presentation(n, kids) {
    if ((n.params || {}).request) return h(PickerRequest, { key: n.dismiss, n });
    const isAlert = n.style === "alert";
    // Panel chrome colors ride the node, scheme-resolved by the serializer
    // (Color.secondaryBackground / Color.primary) — never hardcode a light
    // palette here, or dark-scheme presented content renders white-on-white.
    // A sheet is its content's ground all the way up, behind the grabber
    // too, as an iPhone draws it: a Form's grouped backdrop, or a grouped
    // list's.
    const backdrop = n.style !== "alert" ? backdropFill((n.ch || [])[0]) : null;
    const panelBg = backdrop
      || (n.style !== "alert" && sheetHoldsGroupedList(n) ? (pageDark() ? (isDesktop() ? MAC_DARK_PAGE : "#1c1c1e") : GROUPED_BACKGROUND(false)) : null)
      || rgba(n.bg) || "#fff";
    const headColor = n.color ? rgba(n.color) : undefined;
    const messageColor = n.color
      ? rgba([n.color[0], n.color[1], n.color[2], n.color[3] * 0.65])
      : "rgba(0,0,0,0.6)";
    if (isAlert) {
      const head = [];
      if (n.title) {
        head.push(h("div", {
          key: "t",
          style: { fontWeight: 600, fontSize: 17, textAlign: "center", color: headColor },
        }, n.title));
      }
      if (n.message) {
        head.push(h("div", {
          key: "m",
          style: { fontSize: 14, color: messageColor, textAlign: "center" },
        }, n.message));
      }
      kids = [h("div", {
        key: "head",
        style: {
          display: "flex", flexDirection: "column", gap: 8,
          marginBottom: kids.length ? 14 : 0,
          fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
        },
      }, head), ...kids];
    }
    // Sheets: Apple's shapes. Compact width → a bottom sheet with a grabber,
    // sliding up over a scrim, resting at its detents (`.presentationDetents`:
    // medium = half, large = full, the default), dragged down to dismiss
    // unless `.interactiveDismissDisabled`. Regular width → a centered
    // modal card sized to its content (a growing content — a
    // NavigationStack / List / Form — gets a fixed height so it scrolls
    // inside). `.fullScreenCover`: the panel IS the screen.
    const compact = window.innerWidth < 700;
    const child = (n.ch || [])[0] || {};
    const greedy = !!child.growH || !!child.expandH;
    const params = n.params || {};
    const cover = !!(params.cover === "1");
    const detents = (params.detents || "large").split(",");
    // `.presentationDragIndicator(.automatic)`: shown when there is a
    // detent to drag to.
    const grabber = (params.grabber === "1" || (params.grabber !== "0" && detents.length > 1)) && !cover && compact;
    const canDismiss = params.nodismiss !== "1" && !cover;
    if (cover) {
      return h("div", { style: { position: "fixed", inset: 0, display: "flex", zIndex: 20, background: panelBg, flexDirection: "column", alignItems: "stretch" } }, kids);
    }
    if (isAlert) {
      return h("div", {
        style: { position: "fixed", inset: 0, display: "flex", zIndex: 20, alignItems: "center", justifyContent: "center", background: "rgba(0,0,0,0.35)" },
        onClick: () => sendEvent(n.dismiss, ""),
      }, h("div", {
        onClick: (e) => e.stopPropagation(),
        style: { background: panelBg, borderRadius: 14, minWidth: 280, maxWidth: 420, padding: 20, boxShadow: "0 12px 40px rgba(0,0,0,0.3)", display: "flex", flexDirection: "column", alignItems: "center" },
      }, kids));
    }
    const sheet = h(Sheet, { key: n.dismiss, n, kids, compact, greedy, panelBg, detents, grabber, canDismiss });
    // At regular width the sheet belongs to the window, as the Mac's does:
    // centred on it, everything behind dimmed — drawn at the root, not in
    // the column that presented it (whose own containing block, a column
    // with a transform or a filter, would hold a fixed layer to itself).
    return compact ? sheet : window.ReactDOM.createPortal(sheet, container, n.dismiss);
  }

  /// The sheet panel with its entrance animation, detents and drag-to-dismiss.
  function Sheet({ n, kids, compact, greedy, panelBg, detents, grabber, canDismiss }) {
    const [shown, setShown] = R.useState(false);
    // Regular width, a growing content (a Form, a List): the Mac's sheet is
    // as tall as its rows, up to most of the window. Laid out at the most it
    // may be, then fitted to what its scroll holds.
    const panelRef = R.useRef(null);
    const [fitted, setFitted] = R.useState(null);
    R.useLayoutEffect(() => {
      if (compact || !greedy) return;
      const panel = panelRef.current;
      const scroller = panel && panel.querySelector("[data-edge-scroll],[data-iso-scroll]");
      if (!scroller) return;
      const most = Math.min(window.innerHeight * 0.85, 760);
      // What the scroll holds, which its scrollHeight does not say when it
      // is less than the scroll's own height: the lowest of its children
      // (through `display: contents` wrappers), plus its bottom padding.
      const top = scroller.getBoundingClientRect().top - scroller.scrollTop;
      let bottom = top;
      const lowest = (el) => {
        for (const c of el.children) {
          if (getComputedStyle(c).display === "contents") lowest(c);
          else bottom = Math.max(bottom, c.getBoundingClientRect().bottom);
        }
      };
      lowest(scroller);
      const held = bottom - top + (parseFloat(getComputedStyle(scroller).paddingBottom) || 0);
      const needed = panel.offsetHeight - scroller.clientHeight + held;
      const next = Math.round(Math.max(240, Math.min(needed, most)));
      if (fitted == null || Math.abs(next - fitted) > 1) setFitted(next);
    });
    const [detent, setDetent] = R.useState(detents.includes("medium") ? "medium" : "large");
    const [dragY, setDragY] = R.useState(0);
    const drag = R.useRef({ active: false, y: 0, dragging: false });
    R.useEffect(() => { const id = requestAnimationFrame(() => setShown(true)); return () => cancelAnimationFrame(id); }, []);
    const dismiss = () => { setShown(false); setTimeout(() => sendEvent(n.dismiss, ""), 220); };
    // The large detent reaches the status bar, as iOS 26's does.
    const heightFor = (d) => d === "medium" ? "50%" : "calc(100% - max(env(safe-area-inset-top, 0px), 10px))";
    // The grabber and the sheet's own top edge take the drag; the content
    // scrolls as usual.
    const onDown = (e) => { if (!compact) return; drag.current = { active: true, y: e.clientY, dragging: false }; };
    const onMove = (e) => {
      const d = drag.current; if (!d.active) return;
      const dy = e.clientY - d.y;
      if (!d.dragging) { if (Math.abs(dy) < 6) return; d.dragging = true; e.currentTarget.setPointerCapture(e.pointerId); }
      setDragY(Math.max(0, dy));
    };
    const onUp = () => {
      const d = drag.current; if (!d.active) return; d.active = false;
      const h = window.innerHeight;
      if (dragY > h * 0.18 && (detent === "large" ? (detents.includes("medium") ? false : canDismiss) : canDismiss)) { dismiss(); return; }
      if (dragY > h * 0.18 && detent === "large" && detents.includes("medium")) { setDetent("medium"); setDragY(0); return; }
      if (dragY > h * 0.18 && !canDismiss) { setDragY(0); return; }
      setDragY(0);
    };
    // iOS 26: at the medium detent the sheet floats, glass inset 8pt from
    // the screen's edges with its corners rounded all round; at the large
    // one it meets the edges, its top corners the screen's.
    const floating = detent === "medium";
    const panelStyle = compact
      ? {
          background: floating ? (pageDark() ? "rgba(30,30,32,0.78)" : "rgba(247,247,249,0.78)") : panelBg,
          ...(floating ? {
            backdropFilter: "blur(30px) saturate(1.8)", WebkitBackdropFilter: "blur(30px) saturate(1.8)",
            borderRadius: 42, marginBottom: 8, width: "calc(100% - 16px)",
            "--iso-sheet-grouped-bg": "transparent",
            "--iso-sheet-cell-bg": pageDark() ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.05)",
          } : { borderTopLeftRadius: 50, borderTopRightRadius: 50, width: "100%" }),
          boxSizing: "border-box", height: heightFor(detent),
          overflow: "hidden", padding: greedy ? 0 : "8px 16px 16px",
          boxShadow: "0 -8px 32px rgba(0,0,0,0.25)",
          display: "flex", flexDirection: "column", alignItems: "stretch",
          transform: shown ? `translateY(${dragY}px)` : "translateY(100%)",
          transition: drag.current.dragging ? "none" : "transform 0.24s cubic-bezier(0.2,0.8,0.2,1)",
          paddingBottom: greedy || floating ? 0 : "calc(16px + var(--iso-safe-bottom, env(safe-area-inset-bottom, 0px)))",
        }
      : {
          background: panelBg, borderRadius: 14, boxSizing: "border-box",
          width: greedy ? "min(560px, calc(100% - 64px))" : "auto",
          minWidth: 280, maxWidth: "min(640px, calc(100% - 64px))",
          // The Mac's: as tall as its content (a Form's rows too), up to most
          // of the window, then it scrolls inside; centred on the window.
          height: greedy ? (fitted != null ? fitted : "min(85%, 760px)") : "auto", maxHeight: "min(85%, 760px)",
          overflow: "hidden", padding: greedy ? 0 : 16, boxShadow: "0 12px 40px rgba(0,0,0,0.35)",
          display: "flex", flexDirection: "column", alignItems: "stretch",
          transform: shown ? "scale(1)" : "scale(0.97)", opacity: shown ? 1 : 0,
          transition: "transform 0.2s cubic-bezier(0.2,0.8,0.2,1), opacity 0.18s ease-out",
        };
    return h("div", {
      style: {
        // The dynamic viewport: on a phone browser the layout viewport runs
        // under the collapsed toolbar, and a sheet sized to it would keep
        // its last rows there.
        position: "fixed", inset: 0, height: "100dvh", display: "flex", zIndex: 20,
        alignItems: compact ? "flex-end" : "center", justifyContent: "center",
        // The Mac dims its window a quarter behind a sheet; a phone more.
        background: shown ? (compact ? "rgba(0,0,0,0.35)" : "rgba(0,0,0,0.25)") : "rgba(0,0,0,0)", transition: "background 0.22s",
      },
      onClick: () => { if (canDismiss) dismiss(); },
    }, h("div", {
      ref: panelRef,
      onClick: (e) => e.stopPropagation(),
      onPointerDown: onDown, onPointerMove: onMove, onPointerUp: onUp, onPointerCancel: onUp,
      style: panelStyle,
    }, grabber ? h("div", { key: "grab", style: { alignSelf: "center", width: 36, height: 5, borderRadius: 3, background: "rgba(120,120,128,0.45)", margin: "6px 0 2px", flex: "none" } }) : null,
       // The body keeps the home indicator's inset below its last row.
       h("div", { key: "body", className: "iso-sheet-body", style: { flex: "1 1 auto", minHeight: 0, display: "flex", flexDirection: "column", alignItems: "stretch", overflowY: greedy ? "hidden" : "auto", "--iso-safe-top": "0px", ...(pageDark() && !(compact && detent === "medium") ? { "--iso-sheet-grouped-bg": compact ? "#1c1c1e" : MAC_DARK_PAGE, "--iso-sheet-cell-bg": compact ? "#2c2c2e" : "#2b2b2d" } : {}), "--iso-inset-bottom": compact ? "var(--iso-safe-bottom, env(safe-area-inset-bottom, 0px))" : "0px" } }, kids)));
  }

  let renderDepth = 0;

  // One list row, rendered with the list context it was reached under (the
  // render walk carries that context in these module variables; a memoized
  // row renders later, outside the walk, so it puts them back itself).
  // Lazy lists: a row not built this frame is a placeholder the height the
  // row last had here (keyed by the row's identity).
  const rowHeights = new Map();

  const ListCell = R.memo(function ListCell({ n, axis, listStyle, separators, minRow, sidebar, splitBack, depth }) {
    R.useLayoutEffect(() => {
      if (!n.key || (n.params || {}).placeholder) return;
      const escaped = window.CSS && CSS.escape ? CSS.escape(n.key) : n.key.replace(/"/g, '\\"');
      const el = document.querySelector(`[data-iso-key="${escaped}"]`);
      if (el) rowHeights.set(n.key, el.getBoundingClientRect().height);
    });
    if ((n.params || {}).placeholder) {
      return h("div", {
        "data-iso-cell": "1", "data-iso-key": n.key,
        style: { height: rowHeights.get(n.key) || 60, flex: "0 0 auto", alignSelf: "stretch" },
      });
    }
    const saved = [currentListStyle, currentListSeparators, currentListMinRowHeight, inSidebar, currentSplitBack, renderDepth, inListCell];
    currentListStyle = listStyle; currentListSeparators = separators; currentListMinRowHeight = minRow; inSidebar = sidebar;
    currentSplitBack = splitBack; renderDepth = depth; inListCell = !sidebar;
    try { return render(n, "cell", axis); }
    finally { [currentListStyle, currentListSeparators, currentListMinRowHeight, inSidebar, currentSplitBack, renderDepth, inListCell] = saved; }
  }, (a, b) => a.n === b.n && a.axis === b.axis && a.listStyle === b.listStyle
    && a.separators === b.separators && a.minRow === b.minRow && a.sidebar === b.sidebar);

  // Inside a List or Form row (not the sidebar's): at regular width a
  // button of the automatic style there is the Mac's push button.
  let inListCell = false;

  // The fixed frame (`.frame(width:height:)`) directly around the node being
  // rendered, if any: which of its dimensions are set.
  let sizedByFrame = null;
  // Whether the node being rendered sits in a box or a VStack (whose width
  // bounds it), not a horizontal stack, a scroll or a ZStack.
  let widthCappedByParent = false;
  function render(n, key, parentAxis) {
    renderDepth += 1;
    const presented = n.k === "presentation";
    if (presented) presentationDepth += 1;
    // A Form's row is a row as a List's is (`inListCell`).
    const formRow = !!(n.params && n.params.form === "row");
    const cellBefore = inListCell;
    if (formRow) inListCell = true;
    try {
      return renderNode(n, key, parentAxis);
    } finally {
      renderDepth -= 1;
      if (presented) presentationDepth -= 1;
      if (formRow) inListCell = cellBefore;
    }
  }

  // A node's fixed frame, looking through wrapper boxes (a `.frame(width:)`
  // under an `.overlay` or a tap) — the minimum a stack layer keeps.
  function fixedSize(n) {
    let node = n;
    for (let depth = 0; node && depth < 6; depth++) {
      // A GeometryReader is sized by its parent, never by what it built —
      // its content was built for a size the host reported (or guessed
      // before the first report), and letting that size back out as a
      // minimum would pin the guess in place, with no way to correct it.
      if (node.params && node.params.geo) break;
      const w = node.width != null ? node.width : undefined;
      const h2 = node.height != null ? node.height : undefined;
      if (w != null || h2 != null) return { w: w != null ? w : 0, h: h2 != null ? h2 : 0 };
      if (node.k !== "box") break;
      const content = (node.ch || []).filter((c) => !(c.params && c.params.layer));
      if (content.length !== 1) break;
      node = content[0];
    }
    return { w: 0, h: 0 };
  }

  // The width cap of a `.frame(maxWidth:)` at or under a chain of wrapper
  // boxes (a modifier's: a background, a padding, an offset), with the
  // paddings on the way: what those boxes are at most, as in SwiftUI a
  // modifier's box is its frame's size, the lesser of the cap and what it
  // is offered. Null when there is no cap, or the chain has a width of its
  // own or a greedy node on the way.
  function cappedWidth(n) {
    let extra = 0;
    let node = n;
    for (let depth = 0; node && depth < 8; depth++) {
      if (node.width != null || (node.params && node.params.geo)) return null;
      if (node.params && node.params.maxW != null) return extra + Number(node.params.maxW);
      if (node.growW || node.expandW) return null;
      if (node.k !== "box") return null;
      if (node.padding) extra += (node.padding[1] || 0) + (node.padding[3] || 0);
      const content = (node.ch || []).filter((c) => !(c.params && c.params.layer));
      if (content.length !== 1) return null;
      node = content[0];
    }
    return null;
  }

  function renderNode(n, key, parentAxis) {
    if (n.k === "hostView" && (n.view === "navbar" || n.view === "tabbar")) {
      // Bars ignore box decorations; they are chrome rows. A bar's child is
      // a `.principal` item's own view.
      return h(R.Fragment, { key }, hostView(n, {}, (n.ch || []).map((c, i) => render(c, `${i}:${c.k}`, "h"))));
    }
    if (key === "root") {
      // The root view keeps its own size, centered in the canvas — the way
      // SwiftUI (and the native renderers) place a content-sized root — so
      // `.background` on a root VStack wraps the content instead of
      // painting the whole screen. Greedy roots (navigation, lists,
      // spacers) still fill the canvas via the ZStack-layer rules.
      return h("div", {
        key,
        style: { width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center", minHeight: 0, minWidth: 0 },
      }, render(n, "root-node", "z"));
    }
    const props = interactive(n, { key, style: baseStyle(n) });
    const s = props.style;
    // Greedy nodes fill their parent: grow along the parent's main axis,
    // stretch across it (SwiftUI greediness, computed by the serializer).
    if ((parentAxis === "v" && n.growH) || (parentAxis === "h" && n.growW)) {
      s.flexGrow = 1;
      s.minHeight = 0;
      s.minWidth = 0;
    }
    if ((parentAxis === "v" && n.growW) || (parentAxis === "h" && n.growH)) {
      s.alignSelf = "stretch";
    }
    // A `Grid`'s line that is not a row (a divider) spans every column.
    const gridLine = (n.params || {}).gridLine;
    if (gridLine != null && !(n.params || {}).gridRow) {
      s.gridRow = Number(gridLine) + 1;
      s.gridColumn = "1 / -1";
    }
    // A flex child may not shrink below its content by default, so one long
    // word (a resume command, an address) widens the whole row. SwiftUI
    // squeezes such a child and lets it truncate; a fixed frame keeps its
    // size through the minimum set with its width.
    // A wrapper round a fixed frame (a button whose label has a set size)
    // keeps that size: SwiftUI's stack gives its rigid children their size
    // first, where flexbox would shrink them with the rest.
    if (parentAxis === "h" && n.width == null) {
      if (n.k === "box" && fixedSize(n).w > 0) s.flexShrink = 0;
      else s.minWidth = 0;
    }
    if (parentAxis === "v" && n.height == null) s.minHeight = 0;
    // A VStack or a modifier's box proposes its own width to its content,
    // which is never wider unless it is fixed (a frame, `.fixedSize`): a
    // column's child left at its content's width would run past it (a
    // one-line command beside two buttons ran under them).
    if (widthCappedByParent && n.width == null && s.maxWidth == null) s.maxWidth = "100%";
    // In a ZStack layer, greedy nodes fill the stack (e.g. a shape backdrop).
    if (parentAxis === "z") {
      if (n.growW) s.width = "100%";
      if (n.growH) s.height = "100%";
    }
    // `.frame(maxWidth/Height: .infinity)` along the parent's main axis means
    // "fill the remaining space", which in CSS is flex-grow — NOT a 100%
    // preferred size, which would overflow the row and shrink the fixed
    // siblings. Across the main axis it is a plain 100%.
    if (n.expandW) {
      if (parentAxis === "h") {
        s.flexGrow = 1;
        s.flexBasis = 0;
        s.minWidth = 0;
      } else {
        s.width = "100%";
      }
    }
    if (n.expandH) {
      if (parentAxis === "v") {
        s.flexGrow = 1;
        s.flexBasis = 0;
        s.minHeight = 0;
      } else {
        s.height = "100%";
      }
    }
    // Finite frame bounds: a `.frame(maxWidth: 400)` view is flexible up to
    // the cap (it takes what it is offered, then stops growing).
    const bounds = n.params || {};
    if (bounds.maxW != null && n.width == null) {
      s.maxWidth = Number(bounds.maxW); if (!n.expandW) s.width = "100%"; s.boxSizing = "border-box";
      // Capped, it is not greedy any more: it takes up to its cap and sits
      // where its parent aligns it (SwiftUI centres a `.frame(maxWidth: 320)`
      // box inside an `.infinity` frame) instead of growing from the edge.
      s.flexGrow = 0;
      if (s.alignSelf === "stretch") delete s.alignSelf;
    }
    // A wrapper round a capped frame takes its size, not its content's: the
    // box's width, up to the cap.
    if (bounds.maxW == null && n.k === "box") {
      const cap = cappedWidth(n);
      if (cap != null) {
        s.maxWidth = cap; s.width = "100%"; s.boxSizing = "border-box";
        s.flexGrow = 0;
        if (s.alignSelf === "stretch") delete s.alignSelf;
      }
    }
    if (bounds.maxH != null && n.height == null) {
      s.maxHeight = Number(bounds.maxH); s.boxSizing = "border-box";
      // Round greedy content (a ScrollView in `.frame(maxHeight: 92)`) it is
      // its cap, as SwiftUI gives the content min(offer, cap), shrinking if
      // its column is squeezed. Left to its content's height, a scroll's
      // zero basis made it 0px tall: a composer's suggestions never showed.
      const content = (n.ch || []).filter((c) => !(c.params && c.params.layer));
      if (!n.expandH && content.some((c) => c.growH || c.expandH)) {
        s.height = Number(bounds.maxH);
        s.flexShrink = 1;
        s.minHeight = 0;
      }
    }
    if (bounds.minW != null) s.minWidth = Number(bounds.minW);
    if (bounds.minH != null) s.minHeight = Number(bounds.minH);
    // SwiftUI fixed frames don't compress; keep flexbox from shrinking them
    // along the parent's main axis.
    if (parentAxis === "h" && n.width != null) s.flexShrink = 0;
    if (parentAxis === "v" && n.height != null) s.flexShrink = 0;
    const childAxis = n.k === "stack" ? n.axis : "v";
    // Key children by kind (and stack axis / host-view kind), not bare index:
    // when navigation swaps a whole subtree, a same-position node of a
    // different kind must REMOUNT, not be incrementally patched — React's
    // style diffing across such transitions has left stale inline styles
    // (e.g. a dropped flex-grow centering a re-visited pane).
    let tabPill = null;
    if (n.k === "hostView" && n.view === "tabs" && (n.params || {}).style === "tabBarOnly") {
      const tp = n.params;
      const labels = [];
      for (let i = 0; i < Number(tp.count || 0); i++) labels.push(tp["label" + i] || "");
      tabPill = {
        options: labels, selected: Number(tp.selected || 0), consumed: false,
        depth: renderDepth + 1, // the selected tab's root, rendered next
        onSelect: (i) => sendEvent(n.edit, String(i)),
      };
      pendingTabPill = tabPill;
    }
    // A screen's chrome (a navstack, a safe-area inset stack): find the
    // content's edge scroll before the children render, so the scroll takes
    // the chrome's insets as padding and flows beneath it — and, on a
    // document-scrolled page, is the page's scroll. Every navstack claims
    // it, not only one whose bar pins over the content: under a large title
    // the scroll takes no top inset, but it is still the screen's scroll
    // (unclaimed, it was a bounded scroll inside the page's content-sized
    // chain, and a Form under a large title came out with no height at all
    // on a phone-width page).
    let ownsEdgeScroll = false;
    const navContent = n.k === "hostView" && n.view === "navstack"
      ? ((n.ch || []).length === 1 || ((n.params || {}).principalContent === "1" && (n.ch || []).length === 2) ? n.ch[0] : null)
      : null;
    if (navContent) {
      const target = edgeScroll(navContent);
      if (target) { edgeScrolls.add(target); ownsEdgeScroll = true; }
    } else if (n.k === "stack" && (n.params || {}).inset && (n.ch || []).length === 2) {
      const target = edgeScroll(n.ch[(n.params || {}).inset === "top" ? 1 : 0]);
      if (target) { edgeScrolls.add(target); ownsEdgeScroll = true; }
    }
    // A compact list renders inset-grouped (iPhone); its rows read the
    // style while they render.
    const isList = n.k === "scroll" && !!(n.params || {}).list;
    // `.listStyle(.plain)`: rows straight on the page with hairlines (the
    // Messages inbox); otherwise a phone shows the grouped card.
    const plainList = isList && !isDesktop() && (n.params || {}).listStyle === "plain";
    const insetGrouped = isList && !isDesktop() && !plainList;
    const sidebarList = isList && isDesktop() && inSidebar > 0;
    const previousSeparators = currentListSeparators;
    if (isList) currentListSeparators = (n.params || {}).separators !== "0";
    const previousMinRowHeight = currentListMinRowHeight;
    if (isList) currentListMinRowHeight = (n.params || {}).minRowHeight != null ? Number(n.params.minRowHeight) : null;
    const previousListStyle = currentListStyle;
    if (insetGrouped) currentListStyle = "insetGrouped";
    else if (plainList) currentListStyle = "plain";
    else if (sidebarList) currentListStyle = "sidebar";
    const isSplit = n.k === "hostView" && n.view === "navsplit";
    let kids;
    try {
      kids = (n.ch || []).map((c, i) => {
        // Children key on their identity (the view's, `ForEach` ids in it),
        // so a row keeps its DOM when rows come and go around it; the
        // runtime's own unkeyed nodes key on position.
        const childKey = c.key != null ? `k${c.key}|${c.k}` : `${i}:${c.k}${c.axis || ""}${c.view || ""}`;
        // A list row renders behind a memo: a patch that leaves the row's
        // node alone (the flat tree keeps its object) skips it entirely, as
        // a collection view leaves its unchanged cells alone.
        if (c.params && c.params.cell) {
          return h(ListCell, {
            key: childKey, n: c, axis: childAxis, listStyle: currentListStyle,
            separators: currentListSeparators, minRow: currentListMinRowHeight, sidebar: inSidebar,
            splitBack: currentSplitBack, depth: renderDepth,
          });
        }
        // The split's first column is its sidebar.
        if (isSplit && i === 0) inSidebar++;
        // A frame's own size is its child's to fill (a 1pt hairline is
        // `Rectangle().frame(height: 1)`): no minimum of the shape's own.
        const sizedBefore = sizedByFrame;
        sizedByFrame = n.k === "box" ? { w: n.width != null, h: n.height != null } : null;
        const cappedBefore = widthCappedByParent;
        widthCappedByParent = n.k === "box" || (n.k === "stack" && n.axis === "v");
        try { return render(c, childKey, childAxis); }
        finally { sizedByFrame = sizedBefore; widthCappedByParent = cappedBefore; if (isSplit && i === 0) inSidebar--; }
      });
    } finally {
      currentListStyle = previousListStyle;
      currentListSeparators = previousSeparators;
      currentListMinRowHeight = previousMinRowHeight;
    }
    if (tabPill) pendingTabPill = null;

    switch (n.k) {
      case "stack": {
        // `Grid`: a CSS grid of auto columns — each as wide as its widest
        // cell, shrinking toward its narrowest (text wrapping, its row
        // growing) when the grid is offered less, as a table does.
        if ((n.params || {}).grid) {
          const rows = (n.ch || []).filter((c) => (c.params || {}).gridRow);
          s.display = "grid";
          s.gridTemplateColumns = `repeat(${Number(n.params.grid)}, auto)`;
          s.columnGap = rows.length && rows[0].spacing != null ? rows[0].spacing : 8;
          s.rowGap = n.spacing != null ? n.spacing : 8;
          s.justifyContent = "start";
          s.minWidth = 0;
          s.maxWidth = "100%";
          return h("div", props, kids);
        }
        // A `GridRow`: no box of its own; its cells go straight into the
        // grid's columns, on its line.
        if ((n.params || {}).gridRow) {
          const line = Number((n.params || {}).gridLine || 0) + 1;
          return h(R.Fragment, { key }, kids.map((kid, i) => h("div", {
            key: i,
            style: {
              gridRow: line, gridColumn: i + 1,
              justifySelf: alignCSS[n.alignH] || "center", alignSelf: alignCSS[n.alignV] || "center",
              display: "flex", flexDirection: "column", minWidth: 0, maxWidth: "100%",
            },
          }, kid)));
        }
        // The desktop has the Mac's toolbar, not a bottom bar: a `.bottomBar`
        // of buttons draws nothing here (its navigation stack's bar has
        // them: liftedBarButtons).
        if (isDesktop() && liftedBottomBar(n) && kids.length === 2) kids = [kids[0], h("div", { key: "lifted" })];
        if ((n.params || {}).inset && kids.length === 2) {
          return h(InsetStack, { key, n, style: s, kids, edge: n.params.inset, hasEdgeScroll: ownsEdgeScroll, fixed: docScroll() && ownsEdgeScroll });
        }
        if (n.axis === "z") {
          // Layers stretch over the whole stack; each aligns its child by
          // the ZStack's alignment (SwiftUI's ZStack(alignment:)).
          const place = `${alignCSS[n.alignV] || "center"} ${alignCSS[n.alignH] || "center"}`;
          s.display = "grid";
          s.placeItems = "stretch";
          // Never narrower than its layers' minimum (a 44pt avatar under a
          // presence dot kept its size while the row squeezed the stack).
          s.minWidth = "min-content";
          kids = kids.map((kid, i) => {
            const c = (n.ch || [])[i] || {};
            return h("div", {
              key: i,
              style: {
                gridArea: "1 / 1", display: "grid", placeItems: place,
                // A fixed-size layer keeps its size as the stack's minimum
                // (an avatar under a presence dot); flexible layers may shrink.
                minWidth: fixedSize(c).w, minHeight: fixedSize(c).h,
                width: c.growW ? "100%" : undefined,
                height: c.growH ? "100%" : undefined,
                // Each layer stacks above the previous even when an earlier
                // layer contains positioned content (the map's canvas).
                position: "relative", zIndex: i,
                // A layer spans the whole stack, but only its content is
                // hittable: the empty part lets taps through to the layers
                // below (a send button over a text field must not swallow
                // taps on the field). Inherited: the child below re-enables
                // it (all of the bottom layer, what can be hit above it).
                pointerEvents: "none",
              },
            }, h("div", {
              // The bottom layer takes the pointer over its box; those above
              // it only where they have something to hit (a full-size layer
              // of controls over a map must leave the map its drags).
              className: i > 0 ? "iso-pass" : undefined,
              style: {
                pointerEvents: i > 0 ? undefined : "auto", display: "flex",
                minWidth: fixedSize(c).w, minHeight: fixedSize(c).h,
                width: c.growW ? "100%" : undefined, height: c.growH ? "100%" : undefined,
              },
            }, kid));
          });
        } else {
          s.display = "flex";
          s.flexDirection = n.axis === "h" ? "row" : "column";
          s.alignItems = n.axis === "h"
            ? (alignCSS[n.alignV] || "center")
            : (alignCSS[n.alignH] || "center");
          s.minHeight = 0;
          s.minWidth = 0;
          s.gap = n.spacing != null ? n.spacing : 8;
        }
        return h("div", props, kids);
      }
      case "text": {
        s.fontSize = textSize(n);
        s.fontWeight = textWeight(n);
        s.color = rgba(n.color);
        s.whiteSpace = "pre-wrap";
        // Text with nowhere to break (a URL, a path) breaks where the line
        // ends, as SwiftUI's does, rather than running past its container
        // (and widening the page). Text that has such a run may also be
        // squeezed by its row to the width there is (`anywhere`); ordinary
        // words keep their width, so a label beside it is not broken in
        // the middle of a word to make room.
        if (/\S{20,}/.test(n.v || "")) s.overflowWrap = "anywhere";
        else { s.overflowWrap = "break-word"; s.minWidth = "min-content"; }
        s.fontFamily = fontFamilyCSS(n.params);
        // `.multilineTextAlignment` reaches the text itself.
        if (n.alignH === "center") s.textAlign = "center";
        else if (n.alignH === "trailing") s.textAlign = "right";
        if (n.lines === 1) {
          // One line: truncate with an ellipsis (a box clamp lets a long
          // token overflow the row instead).
          s.whiteSpace = "nowrap"; s.overflow = "hidden"; s.textOverflow = "ellipsis"; s.minWidth = 0;
          // Never wider than the cell it sits in (a flex item sizes to its
          // content otherwise and runs past an inset group's edge).
          s.maxWidth = "100%";
          // `.truncationMode(.head)` (a path, "…/Developer/visor"): laid
          // right to left, the line overflows and takes its ellipsis at its
          // left edge; the words themselves, isolated, stay left to right.
          if ((n.params || {}).truncation === "head" && !(n.params || {}).symbol) {
            s.direction = "rtl";
            s.textAlign = n.alignH === "center" ? "center" : n.alignH === "trailing" ? "right" : "left";
            const head = (content) => h("span", props, h("span", { dir: "ltr", style: { unicodeBidi: "isolate" } }, content));
            if ((n.params || {}).runs) return head(styledRuns(h, n.v, n.params.runs));
            return head(n.v);
          }
        } else if (n.lines) {
          s.display = "-webkit-box";
          s.WebkitLineClamp = n.lines;
          // `.truncationMode`: CSS only truncates at the end; head/middle fall
          // back to it (the native hosts do the real thing).
          if ((n.params || {}).truncation) { s.textOverflow = "ellipsis"; s.overflow = "hidden"; }
          if ((n.params || {}).lineSpacing) s.lineHeight = `calc(1.25em + ${Number((n.params || {}).lineSpacing)}px)`;
          s.WebkitBoxOrient = "vertical";
          s.overflow = "hidden";
        }
        if ((n.params || {}).symbol) {
          const svg = symbolSVG(h, n.params.symbol, s.fontSize, s.color, n.weight, undefined, n.params.symbol2);
          if (svg) {
            s.display = "inline-flex"; s.alignItems = "center"; s.justifyContent = "center"; s.lineHeight = 1;
            return h("span", props, svg);
          }
        }
        if ((n.params || {}).runs) return h("span", props, styledRuns(h, n.v, n.params.runs));
        return h("span", props, n.v);
      }
      case "spacer":
        s.flexGrow = 1;
        if (n.min != null) { s.minWidth = n.min; s.minHeight = n.min; }
        return h("div", props);
      case "divider":
        s.alignSelf = "stretch";
        s.flex = "0 0 1px";
        s.background = "rgba(120,120,128,0.3)";
        return h("div", props);
      case "scroll":
        if (n.axis === "h") {
          // A horizontal scroll is as tall as its content (a strip of
          // thumbnails in a column), and takes the width it is given.
          s.flex = "0 0 auto";
          s.alignSelf = "stretch";
          s.minWidth = 0;
          s.maxWidth = "100%";
          s.overflowX = "auto";
          s.overflowY = "hidden";
          // Its content starts at the leading edge, as SwiftUI's does.
          s.display = "flex";
          s.flexDirection = "row";
          s.justifyContent = "flex-start";
          s.alignItems = "flex-start";
          props["data-iso-hscroll"] = "1";
        } else {
          s.flex = "1 1 0";
          s.alignSelf = "stretch";
          s.minHeight = 0;
          s.minWidth = 0;
          s.overflowY = "auto";
        }
        // `.scrollIndicators(.hidden)`.
        if ((n.params || {}).indicators === "hidden") {
          s.scrollbarWidth = "none";
          props.className = ((props.className || "") + " iso-no-scrollbar").trim();
        }
        // `.scrollDisabled(true)`: laid out the same, not scrollable.
        const scrollDisabled = (n.params || {}).scrollDisabled === "1";
        if (scrollDisabled) {
          if (n.axis === "h") s.overflowX = "hidden"; else s.overflowY = "hidden";
        }
        // The screen's edge scroll on a document-scrolled page: its content
        // runs on past it into the page, and the page scrolls.
        const documentScrolled = edgeScrolls.has(n) && docScroll();
        if (documentScrolled) {
          // As tall as its content: the page scrolls it.
          s.overflowY = "visible";
          s.flex = "1 0 auto";
          props["data-document-scroll"] = "1";
        }
        s.overscrollBehavior = "contain";
        props["data-iso-scroll"] = "1";
        if (edgeScrolls.has(n)) {
          // The screen's edge scroll: chrome insets become content insets,
          // and end here (nested scrolls are not under the chrome).
          const pad = n.padding || [0, 0, 0, 0];
          s.paddingTop = `calc(${Number(pad[0]) || 0}px + ${INSET_TOP})`;
          // (Document-scrolled, it also clears the keyboard, which covers
          // the page's end: the last row can come up above the composer.)
          s.paddingBottom = `calc(${Number(pad[2]) || 0}px + ${INSET_BOTTOM})`;
          s.scrollPaddingTop = INSET_TOP;
          s.scrollPaddingBottom = INSET_BOTTOM;
          s.boxSizing = "border-box";
          props["data-edge-scroll"] = "1";
          kids = insetsEnd("insets-end", kids);
        }
        if (insetGrouped) {
          const dark = pageDark();
          // In a sheet the grouped ground and cells take the sheet's own
          // (elevated) colours, as iOS raises a sheet's grouped list.
          // (`.scrollContentBackground(.hidden)`: what is behind shows.)
          s.background = (n.params || {}).contentBg === "hidden" ? "transparent" : `var(--iso-sheet-grouped-bg, ${GROUPED_BACKGROUND(dark)})`;
          s["--iso-cell-bg"] = `var(--iso-sheet-cell-bg, ${CELL_BACKGROUND(dark)})`;
          s["--iso-separator"] = SEPARATOR(dark);
          kids = h("div", { key: "grouped", className: "iso-ig" }, kids);
        }
        // `.scrollDismissesKeyboard(.immediately / .interactively)`: a scroll
        // (or a touch drag) blurs the focused field, closing the soft keyboard.
        if ((n.params || {}).dismissKeyboard && (n.params || {}).dismissKeyboard !== "never") {
          // Only the reader's own drag: the scroll's programmatic moves (it
          // follows the keyboard coming up, staying at its bottom) must not
          // close the keyboard they are making room for.
          const dismiss = () => {
            const active = document.activeElement;
            if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA")) active.blur();
          };
          props.onTouchStart = (e) => { e.currentTarget.__isoTouchY = e.touches[0] ? e.touches[0].clientY : null; };
          props.onTouchMove = (e) => {
            const start = e.currentTarget.__isoTouchY;
            if (start != null && e.touches[0] && Math.abs(e.touches[0].clientY - start) > 12) dismiss();
          };
        }
        // `.defaultScrollAnchor(.bottom)` (a chat log): start at the bottom
        // and stay pinned there as content grows, until the user scrolls up.
        const request = (n.params || {}).scrollTo;
        const windowId = (n.params || {}).window;
        const bottom = (n.params || {}).anchor === "bottom";
        const geometryId = (n.params || {}).geometry;
        const phaseId = (n.params || {}).phase;
        if (bottom || request || windowId || documentScrolled || geometryId || phaseId) {
          return h(ManagedScroll, { key, divProps: props, request, windowId, doc: documentScrolled, id: n.key || key, bottom, epoch: (n.params || {}).epoch, rows: (n.params || {}).rows, geometryId, phaseId }, kids);
        }
        return h("div", props, kids);
      case "image": {
        const given = resolveImageSource(n.src);
        const src = /^(https?:|data:|blob:)/.test(given) ? given : assetBase + n.src + (n.src.includes(".") ? "" : ".png");
        props.src = src;
        s.objectFit = n.fit ? "contain" : "cover";
        // scaledToFill: fill the frame box and crop (matching real SwiftUI
        // and the self-drawing renderers) — a bare <img> would render at its
        // natural size and overflow the frame into neighboring content. An
        // explicit propagated frame size (n.width/n.height) wins.
        if (n.resizable && !n.fit) {
          if (n.width == null) s.width = "100%";
          if (n.height == null) s.height = "100%";
        }
        if (!n.resizable && n.width == null) s.maxWidth = "100%";
        if (n.width == null && n.height == null) { s.minWidth = 0; s.minHeight = 0; }
        return h("img", props);
      }
      case "textField":
        return h(TextInput, { key: n.id || key, n: { ...n, baseStyle: s } });
      case "slider":
        props.type = "range";
        props.min = 0;
        props.max = 1;
        props.step = 0.001;
        props.value = n.v || 0;
        props.onChange = (e) => sendEvent(n.edit, e.target.value);
        s.alignSelf = "stretch";
        return h("input", props);
      case "progress":
        if (n.v == null) {
          props.className = ((props.className || "") + " iso-spinner").trim();
          // `.controlSize`: the small spinner is 16px (Apple's), mini 12.
          const size = (n.params || {}).size;
          if (size === "small") { s.width = 16; s.height = 16; s.borderWidth = 2; }
          else if (size === "mini") { s.width = 12; s.height = 12; s.borderWidth = 1.5; }
          else if (size === "large") { s.width = 32; s.height = 32; s.borderWidth = 3; }
          return h("div", props);
        }
        // A linear bar as iOS draws one: a 4pt capsule track with the fill
        // in the tint (the accent unless `.tint` says otherwise), rather
        // than the browser's own <progress>, which differs per browser.
        const fraction = Math.min(1, Math.max(0, Number(n.v) || 0));
        props.role = "progressbar";
        props["aria-valuemin"] = 0;
        props["aria-valuemax"] = 1;
        props["aria-valuenow"] = fraction;
        s.alignSelf = "stretch";
        s.flex = "none";
        s.height = 4;
        s.borderRadius = 2;
        s.overflow = "hidden";
        s.position = "relative";
        s.background = "rgba(120,120,128,0.24)";
        return h("div", props, h("div", {
          style: { position: "absolute", left: 0, top: 0, bottom: 0, width: `${fraction * 100}%`, borderRadius: 2, background: "var(--iso-tint, #0a84ff)" },
        }));
      case "shape":
      case "gradient": {
        // `.trim` on a circle: the stroked arc of a ring, drawn as SVG.
        const trim = (n.params || {}).trim;
        if (trim && n.shape === "circle" && n.stroke) {
          const [from, to] = trim.split(",").map(Number);
          const width = n.strokeWidth || 1;
          const span = Math.max(0, Math.min(1, (to || 0) - (from || 0)));
          if (n.width == null && n.height == null) {
            // Sized from outside (a frame on a wrapper: a rotation, an
            // overlay): the ring fills its box, the arc measured in
            // fractions of the circle (pathLength 1) and the radius from
            // the box's own width.
            return h("svg", {
              ...props,
              style: { ...s, display: "block", overflow: "visible", width: "100%", height: "100%" },
            }, h("circle", {
              pathLength: 1,
              fill: "none", stroke: rgba(n.stroke), strokeWidth: width, strokeLinecap: "round",
              strokeDasharray: `${span} 1`,
              style: {
                cx: "50%", cy: "50%", r: `calc(50% - ${width / 2}px)`,
                transformBox: "fill-box", transformOrigin: "center",
                transform: `rotate(${360 * (from || 0)}deg)`,
              },
            }));
          }
          const size = n.width || n.height;
          const radius = (size - width) / 2;
          const circumference = 2 * Math.PI * radius;
          return h("svg", {
            ...props,
            width: size, height: size, viewBox: `0 0 ${size} ${size}`,
            style: { ...s, display: "block", overflow: "visible" },
          }, h("circle", {
            cx: size / 2, cy: size / 2, r: radius,
            fill: "none", stroke: rgba(n.stroke), strokeWidth: width, strokeLinecap: "round",
            strokeDasharray: `${circumference * span} ${circumference}`,
            // SVG starts at 3 o'clock, as SwiftUI's trim does.
            transform: `rotate(${360 * (from || 0)} ${size / 2} ${size / 2})`,
          }));
        }
        // An app's own shape: its path in the unit square (the `path`
        // param: M/L/Z/R/Q/E), drawn as SVG stretched to the box.
        const custom = (n.params || {}).path;
        if (custom) {
          if (n.width == null && !n.expandW && !(sizedByFrame && sizedByFrame.w)) s.minWidth = 10;
          if (n.height == null && !n.expandH && !(sizedByFrame && sizedByFrame.h)) s.minHeight = 10;
          s.position = s.position || "relative";
          const width = n.strokeWidth || 1;
          return h("div", props,
            h("svg", {
              key: "path", viewBox: "0 0 1 1", preserveAspectRatio: "none",
              style: { position: "absolute", left: 0, top: 0, width: "100%", height: "100%", display: "block", overflow: "visible", pointerEvents: "none" },
            }, h("path", {
              d: svgPathData(custom),
              fill: n.fill ? rgba(n.fill) : "none",
              stroke: n.stroke ? rgba(n.stroke) : "none", strokeWidth: width, vectorEffect: "non-scaling-stroke",
            })),
            ...kids);
        }
        if (n.shape === "circle") s.borderRadius = "50%";
        if (n.shape === "capsule") s.borderRadius = 9999;
        if (n.fill) s.background = fillCSS(n);
        if (n.stroke) s.border = `${n.strokeWidth || 1}px solid ${rgba(n.stroke)}`;
        if (n.width == null && !n.expandW && !(sizedByFrame && sizedByFrame.w)) s.minWidth = 10;
        if (n.height == null && !n.expandH && !(sizedByFrame && sizedByFrame.h)) s.minHeight = 10;
        s.display = "grid";
        s.placeItems = "center";
        return h("div", props, kids);
      }
      case "hostView":
        if (n.view === "navstack") return navStack(n, key, kids, ownsEdgeScroll);
        if (n.view === "navsplit") return navSplit(n, key, kids);
        if (n.view === "tabs") {
          if ((n.params || {}).style === "sidebarAdaptable") {
            return h(SidebarTabs, { key, n, kids });
          }
          if ((n.params || {}).style === "tabBarOnly" && tabPill && tabPill.consumed) {
            // The selected tab's navigation bar took the pill: content only.
            return h("div", {
              key,
              style: { display: "flex", flexDirection: "column", flex: 1, minHeight: 0, alignSelf: "stretch", width: "100%" },
            }, kids);
          }
          if ((n.params || {}).style === "tabBarOnly") {
            // iPad / macOS-15 `.tabBarOnly` with a non-navigation tab root:
            // a centered segmented pill in a slim strip at the TOP.
            const p = n.params || {};
            const dark = p.dark === "1";
            const count = Number(p.count || 0);
            const labels = [];
            for (let i = 0; i < count; i++) labels.push(p["label" + i] || "");
            return h("div", {
              key,
              style: { display: "flex", flexDirection: "column", flex: 1, minHeight: 0, alignSelf: "stretch", width: "100%" },
            },
              h("div", {
                key: "topbar",
                style: {
                  display: "flex", justifyContent: "center", alignItems: "center", flex: "none",
                  padding: "6px 12px", background: "transparent",
                },
              }, h(Segmented, {
                options: labels, selected: Number(p.selected || 0), dark, compact: true,
                onSelect: (i) => sendEvent(n.edit, String(i)),
              })),
              h("div", { key: "content", style: { display: "flex", flexDirection: "column", flex: 1, minHeight: 0 } }, kids));
          }
          // Semantic tabs → the selected tab's content over the bottom bar.
          return h("div", {
            key,
            style: { display: "flex", flexDirection: "column", flex: 1, minHeight: 0, alignSelf: "stretch", width: "100%" },
          },
            h("div", { key: "content", style: { display: "flex", flexDirection: "column", flex: 1, minHeight: 0 } }, kids),
            h(R.Fragment, { key: "bar" }, tabBar({ edit: n.edit, params: n.params })));
        }
        return hostView(n, props, kids);
      case "presentation":
        return presentation(n, kids);
      default: {
        // `.background(view)` / `.overlay(view)` layers: absolutely placed
        // over the box's area, behind (z -1) or over (z 1) the content.
        const layerOf = (i) => (((n.ch || [])[i] || {}).params || {}).layer;
        // Whether a layer's subtree has anything that answers to a pointer:
        // a tap, a drag, an edit channel, or a kind that handles its own
        // input (a scroll, a control, a map).
        const layerUsable = (node) => {
          if (!node) return false;
          if (node.tap || node.drag || node.edit) return true;
          if (LAYER_INPUT_KINDS.has(node.k)) return true;
          return (node.ch || []).some(layerUsable);
        };
        // A layer capped by `.frame(maxWidth:)` under the modifiers around
        // it is offered the box's width, as SwiftUI's overlays offer their
        // size: it takes the lesser of its cap and the box, not its
        // content's width (a menu `.frame(maxWidth: 360)` over a composer).
        const layerCappedW = (node) => cappedWidth(node) != null;
        if ((n.ch || []).some((c) => c.params && c.params.layer)) {
          s.position = "relative";
          s.zIndex = 0;
          const wrap = (kid, i, z) => {
            // `.overlay(alignment:)` / `.background(alignment:)`.
            const [ah, av] = ((((n.ch || [])[i] || {}).params || {}).layerAlign || "center,center").split(",");
            // A view its alignment guide moved out of the box floats above
            // the screen's bars (param "float"): a layer of its own.
            if ((((n.ch || [])[i] || {}).params || {}).float === "1") {
              return h(FloatingLayer, {
                key: `layer${i}`,
                alignItems: av === "start" ? "flex-start" : av === "end" ? "flex-end" : "center",
                justifyContent: ah === "start" ? "flex-start" : ah === "end" ? "flex-end" : "center",
                growW: !!((n.ch || [])[i] || {}).growW || layerCappedW((n.ch || [])[i]),
                growH: !!((n.ch || [])[i] || {}).growH,
              }, kid);
            }
            // The layer box itself is pointer-transparent (a corner pencil
            // must not swallow the page's touch scrolling). Its content is
            // pointer-transparent too unless something in it can be used:
            // a stroked border or a shape backdrop fills the box, and a
            // greedy layer that takes pointer events sits on top of every
            // button beneath it.
            const usable = layerUsable((n.ch || [])[i]);
            return h("div", {
              key: `layer${i}`,
              style: {
                // Not clipped to the box, as SwiftUI's overlays and
                // backgrounds aren't: a view moved out of it (a menu floated
                // above a composer by its alignment guide) still shows.
                position: "absolute", inset: 0, display: "flex", zIndex: z, overflow: "visible",
                pointerEvents: "none",
                alignItems: av === "start" ? "flex-start" : av === "end" ? "flex-end" : "center",
                justifyContent: ah === "start" ? "flex-start" : ah === "end" ? "flex-end" : "center",
              },
            }, h("div", {
              style: {
                // A column, as the box's content is laid out: a layer's view
                // greedy across (rows `.frame(maxWidth: .infinity)`)
                // stretches across it, one greedy down grows down it.
                pointerEvents: usable ? "auto" : "none", display: "flex", flexDirection: "column", minWidth: 0, minHeight: 0,
                // A greedy layer (a shape backdrop, a stroked border) fills
                // the box; content-sized layers sit at their alignment.
                width: (n.ch || [])[i] && ((n.ch || [])[i].growW || layerCappedW((n.ch || [])[i])) ? "100%" : undefined,
                height: (n.ch || [])[i] && (n.ch || [])[i].growH ? "100%" : undefined,
                // A capped layer at its alignment within the box's width.
                alignItems: ah === "start" ? "flex-start" : ah === "end" ? "flex-end" : "center",
              },
            }, kid));
          };
          kids = kids.map((kid, i) => {
            const layer = layerOf(i);
            return layer === "background" ? wrap(kid, i, -1) : layer === "overlay" ? wrap(kid, i, 1) : kid;
          });
        }
        if (kids.length > 0) {
          s.display = "flex";
          // A positioning context for `.position`ed children.
          if (!s.position) s.position = "relative";
          s.flexDirection = "column";
          s.alignItems = alignCSS[n.alignH] || "center";
          s.justifyContent = alignCSS[n.alignV] || "center";
          // Shrinkable by default, but a `.frame(minHeight:)` /
          // `.frame(minWidth:)` bound set above stands (a chat log that is
          // at least the viewport tall, bottom-aligned).
          if ((n.params || {}).minH == null) s.minHeight = 0;
          if ((n.params || {}).minW == null) s.minWidth = 0;
        }
        // Semantic list rows carry a `cell` role instead of baked-in
        // chrome — this host's row idiom: comfortable padding, a minimum
        // touch height, and a hairline separator.
        if ((n.params || {}).cell) {
          props["data-iso-cell"] = "1";
          if (n.key) props["data-iso-key"] = n.key;
        }
        if ((n.params || {}).cell === "row") {
          const selected = (n.params || {}).selected === "1";
          // `.listRowSeparator(.hidden)` on this row, or the list's.
          const separators = currentListSeparators && (n.params || {}).noSeparator !== "1";
          // Rows off screen skip layout and paint (sized as last laid out),
          // the way a collection view only lays out what is visible.
          s.contentVisibility = "auto";
          s.containIntrinsicSize = "auto 44px";
          // A row with a view behind it (`.listRowBackground(view)`) draws
          // its own ground and selection: the list paints neither.
          const ownBg = (n.params || {}).rowOwnBg === "1";
          if (currentListStyle === "sidebar" && ownBg) {
            // The sidebar's width, its padding the app's (the sides it left
            // to the list the Mac's).
            s.padding = rowPadding(n.params, [5, 10, 5, 10]); s.minHeight = 28; s.width = "100%";
            s.boxSizing = "border-box"; s.justifyContent = "center"; s.fontSize = 13;
          } else if (currentListStyle === "sidebar") {
            // macOS sidebar rows: compact, no separators, a rounded accent
            // selection with a white label.
            s.padding = "5px 10px"; s.minHeight = 28; s.margin = "1px 10px"; s.borderRadius = 6; s.width = "calc(100% - 20px)"; s.alignSelf = "flex-start";
            s.boxSizing = "border-box"; s.justifyContent = "center"; s.fontSize = 13;
            props.className = ((props.className || "") + " iso-sb-row" + (selected ? " iso-sb-selected" : "")).trim();
            // The Mac's selected row in a focused sidebar (its selected
            // content colour), not the plain system blue.
            if (selected) s.background = "var(--iso-mac-selection)";
          } else {
            // The platform's row metrics, unless the app set its own:
            // `.listRowInsets` on the row ("top,leading,bottom,trailing"),
            // `\.defaultMinListRowHeight` on the list.
            const rowInsets = rowInsetValues(n.params, currentListStyle === "insetGrouped" ? [13, 16, 13, 16] : [11, 16, 11, 16]);
            s.padding = `${rowInsets[0]}px ${rowInsets[3]}px ${rowInsets[2]}px ${rowInsets[1]}px`;
            // The separator runs under the content, from its leading inset
            // to its trailing one, as iOS draws it.
            s["--iso-sep-l"] = `${rowInsets[1]}px`;
            s["--iso-sep-r"] = `${rowInsets[3]}px`;
            // iOS 26's inset-grouped rows are 52pt at the least.
            s.minHeight = currentListMinRowHeight != null ? currentListMinRowHeight : currentListStyle === "insetGrouped" ? 52 : 44;
            s.boxSizing = "border-box";
            s.justifyContent = "center";
            if (currentListStyle === "insetGrouped") {
              // Selected, the cell is the system blue with its text white, as
              // an iPad's inset-grouped sidebar has it.
              props.className = ((props.className || "") + " iso-ig-row" + (separators ? "" : " iso-no-sep")
                + (selected && !ownBg ? " iso-ig-selected" : "")).trim();
              if (selected && !ownBg) s.background = "var(--iso-tint, #0a84ff)";
            } else if (currentListStyle === "plain") {
              // Messages' inbox: the row on the page, a hairline from the
              // text column, a gray highlight for the selected row.
              props.className = ((props.className || "") + " iso-plain-row" + (separators ? "" : " iso-no-sep")).trim();
              if (selected && !ownBg) s.background = "rgba(120,120,128,0.22)";
            } else {
              if (separators) s.borderBottom = "1px solid rgba(120,120,128,0.2)";
              if (selected && !ownBg) s.background = "rgba(10,132,255,0.18)";
            }
          }
        }
        if ((n.params || {}).cell === "footer" && currentListStyle === "insetGrouped") {
          props.className = ((props.className || "") + " iso-ig-footer").trim();
        }
        if ((n.params || {}).cell === "header") {
          if (currentListStyle === "insetGrouped") {
            // A header-less section's header is only the gap before it.
            const empty = !(n.ch || []).some((c) => c.k !== "box" || (c.ch || []).length);
            props.className = ((props.className || "") + " iso-ig-header" + (empty ? " iso-ig-gap" : "")).trim();
          }
          else if (currentListStyle === "sidebar") props.className = ((props.className || "") + " iso-sb-header").trim();
          else if (currentListStyle === "plain" && !(n.ch || []).some((c) => c.k !== "box" || (c.ch || []).length)) {
            // A plain list's header-less section runs on from the one before
            // it, as an iPhone's does: no gap.
            props.className = ((props.className || "") + " iso-plain-gap").trim();
          }
        }
        // A GeometryReader wrapper: measure the box the host actually laid
        // out and report it back ("<w>x<h>" on the `.geo` id), so the guest
        // rebuilds the reader's content against its CONTAINER, not the
        // canvas. The guest ignores same-size re-reports (empty patch), so
        // remounts converge.
        if ((n.params || {}).geo) {
          return h(GeometryBox, { key, divProps: props, geoId: n.params.geo }, kids);
        }
        if ((n.params || {}).fits) {
          return h(FitsBox, { key, divProps: props, axes: n.params.fits, parentAxis, grows: (n.ch || []).map((c) => [!!c.growW, !!c.growH]) }, kids);
        }
        if ((n.params || {}).ctxmenu) attachContextMenu(props, n);
        if ((n.params || {}).swipe) return h(SwipeRow, { key, n, divProps: props }, kids);
        return h("div", props, kids);
      }
    }
  }

  return {
    // `now`: committed before this returns (layout effects included), as a
    // reader's gesture needs; otherwise whenever React schedules it.
    render(tree, now = false) {
      if (now) window.ReactDOM.flushSync(() => root.render(render(tree, "root", "v")));
      else root.render(render(tree, "root", "v"));
    },
  };
}
