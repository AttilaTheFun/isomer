// Decodes the render tree (shared/wire/tree.proto: protobuf) into the
// plain-object shape the React interpreter consumes ({k, v, ch, ...}).
// Hand-written against protobuf's wire format so the web stays npm-free;
// the field numbers MUST match tree.proto's.

const KINDS = [
  "box", "text", "shape", "stack", "spacer", "divider", "scroll", "image",
  "textField", "slider", "gradient", "hostView", "progress", "presentation",
];
const AXES = ["h", "v", "z"];
const ALIGN_H = ["leading", "center", "trailing"];
const ALIGN_V = ["top", "center", "bottom"];
const SHAPES = ["rect", "circle", "capsule"];
const STYLES = ["sheet", "popover", "alert"];

const textDecoder = new TextDecoder();

// A reader over `bytes[start, end)`: protobuf's fields, one at a time.
export function makeReader(bytes, start = 0, end = bytes.length) {
  const buf = bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let pos = start;
  // A varint's low 32 bits as a signed int32 (an int32 field's negative
  // values are ten bytes long) and as an unsigned number (a length, a tag).
  function varint() {
    let lo = 0;
    let shift = 0;
    let byte;
    do {
      byte = buf[pos];
      pos += 1;
      if (shift < 32) lo |= (byte & 0x7f) << shift;
      shift += 7;
    } while (byte & 0x80);
    return lo;
  }
  return {
    buf,
    done: () => pos >= end,
    tag() {
      const tag = varint() >>> 0;
      return [tag >>> 3, tag & 7];
    },
    int32: () => varint() | 0,
    uint: () => varint() >>> 0,
    bool: () => varint() !== 0,
    double() {
      const value = view.getFloat64(pos, true);
      pos += 8;
      return value;
    },
    float() {
      const value = view.getFloat32(pos, true);
      pos += 4;
      return value;
    },
    // A length-delimited field's bounds; the reader moves past it.
    span() {
      const length = varint() >>> 0;
      const from = pos;
      pos += length;
      return [from, pos];
    },
    string() {
      const length = varint() >>> 0;
      const text = textDecoder.decode(buf.subarray(pos, pos + length));
      pos += length;
      return text;
    },
    skip(type) {
      if (type === 0) varint();
      else if (type === 1) pos += 8;
      else if (type === 2) pos += varint() >>> 0;
      else if (type === 5) pos += 4;
    },
  };
}

function color(buf, [from, to]) {
  const r = makeReader(buf, from, to);
  const out = [0, 0, 0, 0];
  while (!r.done()) {
    const [field, type] = r.tag();
    if (type === 5 && field >= 1 && field <= 4) out[field - 1] = r.float();
    else r.skip(type);
  }
  return out;
}

function shadow(buf, [from, to]) {
  const r = makeReader(buf, from, to);
  const out = { color: [0, 0, 0, 0], radius: 0, x: 0, y: 0 };
  while (!r.done()) {
    const [field, type] = r.tag();
    if (field === 1 && type === 2) out.color = color(buf, r.span());
    else if (field === 2 && type === 5) out.radius = r.float();
    else if (field === 3 && type === 5) out.x = r.float();
    else if (field === 4 && type === 5) out.y = r.float();
    else r.skip(type);
  }
  return out;
}

function keyValue(buf, [from, to]) {
  const r = makeReader(buf, from, to);
  let key = "";
  let value = "";
  while (!r.done()) {
    const [field, type] = r.tag();
    if (field === 1 && type === 2) key = r.string();
    else if (field === 2 && type === 2) value = r.string();
    else r.skip(type);
  }
  return [key, value];
}

function node(buf, [from, to]) {
  const r = makeReader(buf, from, to);
  const n = { k: "box" };
  let numeric;
  let hasAxis = false;
  while (!r.done()) {
    const [field, type] = r.tag();
    switch (field) {
      case 1: n.k = KINDS[r.uint()] || "box"; break;
      case 2: n.v = r.string(); break;
      case 3: numeric = r.double(); break; // numeric value (slider/progress)
      case 4: n.id = r.string(); break;
      case 5: n.size = r.double(); break;
      case 6: n.weight = r.int32(); break;
      case 7: n.color = color(buf, r.span()); break;
      case 8: n.lines = r.int32(); break;
      case 9: n.shape = SHAPES[r.uint()]; break;
      case 10: n.fill = color(buf, r.span()); break;
      case 11: n.stroke = color(buf, r.span()); break;
      case 12: n.strokeWidth = r.double(); break;
      case 13: n.axis = AXES[r.uint()]; hasAxis = true; break;
      case 14: n.spacing = r.double(); break;
      case 15: n.min = r.double(); break;
      case 16: n.src = r.string(); break;
      case 17: n.remote = r.bool(); break;
      case 18: n.resizable = r.bool(); break;
      case 19: n.fit = r.bool(); break;
      case 20: n.placeholder = r.string(); break;
      case 21: n.edit = r.string(); break;
      case 22: n.view = r.string(); break;
      case 23: (n.options ??= []).push(r.string()); break;
      case 24: {
        const [key, value] = keyValue(buf, r.span());
        (n.params ??= {})[key] = value;
        break;
      }
      case 25: n.growW = r.bool(); break;
      case 26: n.growH = r.bool(); break;
      case 27: n.alignH = ALIGN_H[r.uint()]; break;
      case 28: n.alignV = ALIGN_V[r.uint()]; break;
      case 29: n.shadow = shadow(buf, r.span()); break;
      case 30: {
        n.padding ??= [];
        if (type === 2) {
          const [start, end] = r.span();
          const packed = makeReader(buf, start, end);
          while (!packed.done()) n.padding.push(packed.double());
        } else {
          n.padding.push(r.double());
        }
        break;
      }
      case 31: n.width = r.double(); break;
      case 32: n.height = r.double(); break;
      case 33: n.expandW = r.bool(); break;
      case 34: n.expandH = r.bool(); break;
      case 35: n.radius = r.double(); break;
      case 36: n.opacity = r.double(); break;
      case 37: n.bg = color(buf, r.span()); break;
      case 38: n.gradient = r.string(); break;
      case 39: n.tap = r.string(); break;
      case 40: n.feedback = r.int32(); break;
      case 41: n.style = STYLES[r.uint()]; break;
      case 42: n.title = r.string(); break;
      case 43: n.message = r.string(); break;
      case 44: n.dismiss = r.string(); break;
      case 45: (n.ch ??= []).push(node(buf, r.span())); break;
      case 46: n.offsetX = r.double(); break;
      case 47: n.offsetY = r.double(); break;
      case 48: n.scale = r.double(); break;
      case 49: n.drag = r.string(); break;
      case 50: n.key = r.string(); break;
      default: r.skip(type);
    }
  }
  if (numeric !== undefined) n.v = numeric;
  if (!hasAxis && (n.k === "stack" || n.k === "scroll")) n.axis = "h";
  return n;
}

export function decodeTree(bytes) {
  const r = makeReader(bytes);
  return node(r.buf, [0, r.buf.length]);
}

// One PatchOp: { path, node, attrsOnly, reorder, order, inserts }.
function patchOp(buf, [from, to]) {
  const r = makeReader(buf, from, to);
  const op = { path: null, node: null, attrsOnly: false, reorder: false, order: [], inserts: [] };
  while (!r.done()) {
    const [field, type] = r.tag();
    if (field === 1 && type === 2) op.path = r.string();
    else if (field === 2 && type === 2) op.node = node(buf, r.span());
    else if (field === 3 && type === 0) op.attrsOnly = r.bool();
    else if (field === 4 && type === 2) {
      const [start, end] = r.span();
      const packed = makeReader(buf, start, end);
      while (!packed.done()) op.order.push(packed.int32());
    } else if (field === 4 && type === 0) op.order.push(r.int32());
    else if (field === 5 && type === 2) op.inserts.push(node(buf, r.span()));
    else if (field === 6 && type === 0) op.reorder = r.bool();
    else r.skip(type);
  }
  return op;
}

// Apply a `Patch` (shared/wire/tree.proto, the ONLY wire format the reactor
// ships) to the retained plain-object tree, returning the new root.
// Copy-on-write: only nodes on each op's path are rebuilt, so unchanged
// subtrees keep their object identity (React.memo-friendly). The first patch
// after start is a single full-tree op at "n"; `retained` is null then.
export function applyPatch(retained, bytes) {
  const r = makeReader(bytes);
  let root = retained;
  while (!r.done()) {
    const [field, type] = r.tag();
    if (field !== 1 || type !== 2) { r.skip(type); continue; } // Patch.ops
    const op = patchOp(r.buf, r.span());
    if (op.path === null) continue;
    if (op.reorder || op.order.length) {
      root = reorderAt(root, op.path, op.order, op.inserts);
      continue;
    }
    if (!op.node) continue;
    root = applyOp(root, op.path, op.node, op.attrsOnly);
  }
  // Non-null after the first (root) op; the empty box guards a degenerate
  // empty-ops patch against a still-empty retained tree.
  return root ?? { k: "box" };
}

// Reorders the children of the node at `path`: for each `order` entry the
// retained child at that index (keeping its object identity, so React skips
// it), or for -1 the next of `inserts`. Copy-on-write along the path.
function reorderAt(root, path, order, inserts) {
  const segments = path.split(".").slice(1).map(Number);
  const rebuild = (cur, depth) => {
    if (depth === segments.length) {
      const old = cur.ch || [];
      let next = 0;
      const ch = order.map((index) => (index >= 0 && index < old.length ? old[index] : inserts[next++]));
      const out = { ...cur };
      if (ch.length) out.ch = ch; else delete out.ch;
      return out;
    }
    const ch = cur.ch.slice();
    ch[segments[depth]] = rebuild(cur.ch[segments[depth]], depth + 1);
    return { ...cur, ch };
  };
  return root ? rebuild(root, 0) : root;
}

// Splices `decoded` into `root` at positional `path` ("n", "n.0.1", ...).
// attrs-only keeps the retained node's children; otherwise the decoded
// subtree (with its own children) replaces it.
function applyOp(root, path, decoded, attrsOnly) {
  const segments = path.split(".").slice(1).map(Number); // drop leading "n"
  const withKeptChildren = (kept) => {
    const merged = { ...decoded };
    if (kept && kept.length) merged.ch = kept;
    else delete merged.ch;
    return merged;
  };
  if (segments.length === 0) {
    return attrsOnly ? withKeptChildren(root ? root.ch : undefined) : decoded;
  }
  const replaceAt = (cur, depth) => {
    const index = segments[depth];
    const child = cur.ch[index];
    const newChild = depth === segments.length - 1
      ? (attrsOnly ? withKeptChildren(child.ch) : decoded)
      : replaceAt(child, depth + 1);
    const ch = cur.ch.slice();
    ch[index] = newChild;
    return { ...cur, ch };
  };
  return replaceAt(root, 0);
}
