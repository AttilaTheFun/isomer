// The web renderers' styling, shared by the React renderer and the DOM
// renderer that replaces it (0.48): fonts, a view's base style, gradients,
// the named grounds and colours in each look (the Mac's at desktop width,
// the iPhone's at a phone's), and text sizes. Pure functions of a node and,
// where the walk's place matters (a split view's sidebar), a `ctx` with
// `inSidebar`; moved from react_renderer.js as they were.

const SYSTEM_FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif";
const MONO_FONT = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace";
export { SYSTEM_FONT, MONO_FONT };

// A text's typeface: a named one (`Font.custom`, the system's after it),
// the design's (`.serif`, `.rounded`, `.monospaced`), else the system's.
export function fontFamilyCSS(p) {
  p = p || {};
  if (p.family) return `"${p.family.replace(/"/g, "")}", ${SYSTEM_FONT}`;
  if (p.mono === "1") return MONO_FONT;
  if (p.design === "serif") return `ui-serif, "New York", Georgia, serif`;
  if (p.design === "rounded") return `ui-rounded, "SF Pro Rounded", ${SYSTEM_FONT}`;
  return SYSTEM_FONT;
}

// A bundled family's heaviest face, from the page's FontFaces (fonts.js
// adds a family's faces under its name with their own weights): null for
// a family the page has no face of (the system's, whose weights are all
// there). Read again whenever the page's set of faces changes.
export const familyWeights = new Map();
let familyWeightsSize = -1;
export function heaviestFace(family) {
  if (typeof document === "undefined" || !document.fonts) return null;
  if (document.fonts.size !== familyWeightsSize) { familyWeights.clear(); familyWeightsSize = document.fonts.size; }
  const key = family.toLowerCase();
  if (familyWeights.has(key)) return familyWeights.get(key);
  let heaviest = null;
  document.fonts.forEach((face) => {
    if (face.family.replace(/^["']|["']$/g, "").toLowerCase() !== key) return;
    const weights = String(face.weight).split(/\s+/)
      .map((w) => (w === "bold" ? 700 : w === "normal" ? 400 : Number(w)))
      .filter((w) => isFinite(w));
    for (const w of weights.length ? weights : [400]) heaviest = Math.max(heaviest ?? 0, w);
  });
  familyWeights.set(key, heaviest);
  return heaviest;
}

// A bold weight the font has no face for is drawn emboldened, as Apple's
// and Android's text are: Chrome's own synthesis of a bundled regular
// face is all but invisible at text sizes, so it is turned off and the
// glyphs are stroked instead, Skia's fake-bold amount (Android's: a
// twenty-fourth of the size at 9 px down to a thirty-second at 36 px),
// which leaves the advances, so the text's measured size, as they were.
export function synthesizeBold(s, family, weight, size) {
  if (!family || !(weight >= 600)) return;
  const heaviest = heaviestFace(family);
  if (heaviest == null || heaviest >= 600) return;
  const px = Number(size) || 17;
  const t = Math.min(1, Math.max(0, (px - 9) / 27));
  const width = px * (1 / 24 + t * (1 / 32 - 1 / 24));
  s.fontSynthesisWeight = "none";
  s.WebkitTextStroke = `${width.toFixed(2)}px ${s.color || "currentColor"}`;
}

// A list row's padding: `.listRowInsets` ("top,leading,bottom,trailing",
// "-" for a side left to the list), each side the list's `d` otherwise.
export const rowInsetValues = (p, d) => {
  const parts = ((p || {}).rowInsets || "").split(",");
  return parts.length === 4
    ? parts.map((x, i) => (x === "-" || x === "" || !isFinite(Number(x)) ? d[i] : Number(x)))
    : d;
};
export const rowPadding = (p, d) => {
  const v = rowInsetValues(p, d);
  return `${v[0]}px ${v[3]}px ${v[2]}px ${v[1]}px`;
};

export const rgba = (c) =>
  c ? `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${c[3]})` : undefined;

export const alignCSS = { leading: "flex-start", center: "center", trailing: "flex-end", top: "flex-start", bottom: "flex-end" };

// The frost of materials and bar buttons.
export const MATERIAL_BLUR = "blur(14px)";

export function gradientCSS(n) {
  if (!n.gradient) return undefined;
  try {
    const g = JSON.parse(n.gradient);
    // A radial gradient's stops start at its start radius: CSS's start
    // at the center, so they move out by the start's share of the end.
    const ell = g.kind === "radial" && Array.isArray(g.ell) ? g.ell : null;
    const inner = ell ? (ell[1] > 0 ? ell[0] / ell[1] : 0)
      : g.kind === "radial" && g.er > 0 ? (g.sr || 0) / g.er : 0;
    const colors = (g.stops || [])
      .map((stop) => `${rgba(stop.c)} ${Math.round((inner + (stop.l || 0) * (1 - inner)) * 1000) / 10}%`)
      .join(",");
    if (!colors) return undefined;
    const at = g.c ? ` at ${g.c[0] * 100}% ${g.c[1] * 100}%` : "";
    // Elliptical: its radii fractions of the box's width and height.
    if (ell) return `radial-gradient(ellipse ${ell[1] * 100}% ${ell[1] * 100}%${at}, ${colors})`;
    if (g.kind === "radial") return `radial-gradient(circle ${Math.max(g.er || 0, 0.01)}px${at}, ${colors})`;
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

export function baseStyle(n, ctx) {
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
  if (n.bg) s.background = namedFillCSS(n.params && n.params.bgName, n.bg, ctx);
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


// The scroll-edge frost's fade: whole under the status bar and the top of
// the bar, then easing to nothing at the bar's bottom edge.
export const FROST_MASK = "linear-gradient(to bottom, rgba(0,0,0,1) 0%, rgba(0,0,0,0.85) 45%, rgba(0,0,0,0.45) 75%, rgba(0,0,0,0) 100%)";
export const BAR_BACKGROUND = (dark) => dark ? "rgba(28,28,30,0.82)" : "rgba(249,249,249,0.82)";
// Apple's grouped palette (systemGroupedBackground,
// secondarySystemGroupedBackground, separator).
export const GROUPED_BACKGROUND = (dark) => dark ? (isDesktop() ? MAC_DARK_PAGE : "#000000") : "#f2f2f7";
// The desktop's dark window (the Mac's grey, not the iPhone's black) and
// its floating sidebar panel, a shade darker.
export const MAC_DARK_PAGE = "#232325";
export const MAC_DARK_SIDEBAR = "#1b1b1d";
// The grounds the guest names ("fillName"), in the desktop's dark palette:
// the Mac's grey where the iPhone's dark is black, and cells a shade up.
export const MAC_DARK_FILLS = {
  groupedBackground: MAC_DARK_PAGE, barBackground: MAC_DARK_PAGE, secondaryBackground: "#2e2e30",
  // A sheet is the window's grey, its groups a step lighter (as the
  // Mac's Form sheets are).
  elevatedGroupedBackground: MAC_DARK_PAGE, elevatedSecondaryBackground: "#2b2b2d",
};
export function fillCSS(n, ctx) { return namedFillCSS(n.params && n.params.fillName, n.fill, ctx); }
export function namedFillCSS(name, color, ctx) {
  // A grouped row's fill in the Mac's sidebar, which has none (an app's
  // own row background puts it under its highlight).
  if (name === "secondaryBackground" && ctx && ctx.inSidebar && isDesktop()) return "transparent";
  if (name && isDesktop() && pageDark() && MAC_DARK_FILLS[name]) return MAC_DARK_FILLS[name];
  // A sheet's grounds are the sheet's to say (a floating sheet's glass
  // shows through them).
  if (name === "elevatedGroupedBackground") return `var(--iso-sheet-grouped-bg, ${rgba(color)})`;
  if (name === "elevatedSecondaryBackground") return `var(--iso-sheet-cell-bg, ${rgba(color)})`;
  return rgba(color);
}
export const CELL_BACKGROUND = (dark) => dark ? (isDesktop() ? "#2e2e30" : "#1c1c1e") : "#ffffff";
export const SEPARATOR = (dark) => dark ? "rgba(84,84,88,0.65)" : "rgba(60,60,67,0.29)";
export const pageDark = () => document.documentElement.dataset.theme === "dark"
  || (!!window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
// The web is a phone when narrow and a desktop when wide: narrow canvases
// take the iOS shapes (large titles, 44pt bars, inset-grouped lists,
// bottom sheets), wide ones the macOS shapes (an inline title in one
// 52px toolbar row, borderless bar buttons, the sidebar list style,
// content-sized sheets).
export const isDesktop = () => window.innerWidth >= 700;
// The Mac's type ramp (points, as its text styles are), for a page as wide
// as the Mac's two columns: the desktop web is the Mac's shape, as a phone's
// width is the iPhone's, whose sizes the guest sends. A text's own size
// (`.system(size:)`, no style) stays as given.
export const MAC_TEXT_SIZES = { largeTitle: 26, title: 22, title2: 17, title3: 15, headline: 13, body: 13,
  callout: 12, subheadline: 11, footnote: 10, caption: 10, caption2: 10 };

// A text's font made smaller, step by step, until it fits its box (no
// longer cut off or clamped) or reaches `minScale` of `size`.
export function fitText(el, size, minScale) {
  let scale = 1;
  el.style.fontSize = size + "px";
  const overflows = () => el.scrollWidth > el.clientWidth + 0.5 || el.scrollHeight > el.clientHeight + 0.5;
  while (overflows() && scale > minScale) {
    scale = Math.max(minScale, scale * 0.92);
    el.style.fontSize = size * scale + "px";
  }
}

export function textSize(n) {
  const style = n.params && n.params.textStyle;
  return isDesktop() && style && MAC_TEXT_SIZES[style] ? MAC_TEXT_SIZES[style] : n.size;
}
// The Mac's headline is bold where the iPhone's is semibold.
export function textWeight(n) {
  return isDesktop() && n.params && n.params.textStyle === "headline" && n.weight === 600 ? 700 : n.weight;
}
