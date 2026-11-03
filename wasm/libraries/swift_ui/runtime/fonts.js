// The app's own fonts, for `Font.custom(name, size:)`: the .ttf/.otf files
// `isomer_web_app(fonts = [...])` puts in the site's fonts/, listed in
// fonts/fonts.json (static_site writes it, `[]` without fonts). Each is added
// to document.fonts under every name `Font.custom` may give it, as iOS
// matches one: its PostScript name ("Karla-Regular"), its full name, its
// family name ("Karla"; under that one with its own weight and slant, so a
// family's faces are told apart), and its file's name with and without the
// extension. The renderers name the family in CSS (react_renderer.js's
// fontFamilyCSS), which matches without regard to case, as Android's
// HostServices.bundledTypeface does.
//
// boot() awaits them before the reactor's first frame: a text is measured
// and drawn with the font itself, never first with the fallback.

/** Adds the fonts listed in `<base>fonts.json` to the page; resolves once
 *  every face is loaded. A site without the list (or a page that is not a
 *  static_site's) loads none. */
export async function loadBundledFonts(base = "./fonts/") {
  if (typeof FontFace === "undefined" || typeof document === "undefined" || !document.fonts) return;
  const baseURL = new URL(base, location.href);
  let files;
  try {
    const response = await fetch(new URL("fonts.json", baseURL), { cache: "no-cache" });
    if (!response.ok) return;
    files = await response.json();
  } catch {
    return;
  }
  if (!Array.isArray(files)) return;
  await Promise.all(files.map(async (file) => {
    try {
      const response = await fetch(new URL(file, baseURL));
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const bytes = await response.arrayBuffer();
      const info = fontInfo(bytes);
      const faces = [];
      const add = (family, descriptors = {}) => {
        if (!family) return;
        // The name as it is: the constructor takes the family's name
        // itself (a dot in a file's name included), and quotes would
        // become part of it in Chrome (nothing in CSS then matches it).
        const face = new FontFace(family, bytes, descriptors);
        document.fonts.add(face);
        faces.push(face.load());
      };
      const plain = new Set([info.postScript, info.full, file, file.replace(/\.[^.]+$/, "")]);
      const family = info.family;
      if (family) {
        plain.delete(family);
        add(family, { weight: String(info.weight), style: info.italic ? "italic" : "normal" });
      }
      for (const name of plain) add(name);
      await Promise.all(faces);
    } catch (error) {
      console.warn(`fonts: ${file} not loaded:`, error);
    }
  }));
}

/** An sfnt font's names (the `name` table, Windows' English records first)
 *  and its weight and slant (the `OS/2` table). */
export function fontInfo(bytes) {
  const view = new DataView(bytes);
  const names = {};
  const preferred = new Set();
  let weight = 400;
  let italic = false;
  const tables = view.getUint16(4);
  for (let i = 0; i < tables; i++) {
    const record = 12 + i * 16;
    const tag = String.fromCharCode(view.getUint8(record), view.getUint8(record + 1), view.getUint8(record + 2), view.getUint8(record + 3));
    const offset = view.getUint32(record + 8);
    if (tag === "OS/2") {
      weight = view.getUint16(offset + 4) || 400;
      italic = (view.getUint16(offset + 62) & 1) !== 0;
    } else if (tag === "name") {
      const count = view.getUint16(offset + 2);
      const strings = offset + view.getUint16(offset + 4);
      for (let j = 0; j < count; j++) {
        const r = offset + 6 + j * 12;
        const platform = view.getUint16(r);
        const encoding = view.getUint16(r + 2);
        const language = view.getUint16(r + 4);
        const id = view.getUint16(r + 6);
        if (![1, 2, 4, 6, 16, 17].includes(id) || preferred.has(id)) continue;
        const length = view.getUint16(r + 8);
        const start = strings + view.getUint16(r + 10);
        if (start + length > bytes.byteLength) continue;
        let value;
        if (platform === 3 || platform === 0) {
          value = new TextDecoder("utf-16be").decode(new Uint8Array(bytes, start, length));
        } else if (platform === 1 && encoding === 0) {
          value = new TextDecoder("latin1").decode(new Uint8Array(bytes, start, length));
        } else {
          continue;
        }
        if (platform === 3 && language === 0x409) {
          names[id] = value;
          preferred.add(id);
        } else if (!(id in names)) {
          names[id] = value;
        }
      }
    }
  }
  return {
    family: names[16] ?? names[1],
    style: names[17] ?? names[2],
    full: names[4],
    postScript: names[6],
    weight,
    italic,
  };
}
