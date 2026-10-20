// Decodes the render-tree FlatBuffer (shared/renderers/tree.fbs) into the
// plain-object shape the React interpreter consumes ({k, v, ch, ...} — the
// former JSON layout). Hand-written against the standard FlatBuffers wire
// format so the web stays npm-free; the field slot numbers MUST match the
// numbered comments in tree.fbs (append-only).

const KINDS = [
  "box", "text", "shape", "stack", "spacer", "divider", "scroll", "image",
  "textField", "slider", "gradient", "hostView", "progress", "presentation",
];
const AXES = ["h", "v", "z"];
const ALIGN_H = ["leading", "center", "trailing"];
const ALIGN_V = ["top", "center", "bottom"];
const SHAPES = ["rect", "circle", "capsule"];
const STYLES = ["sheet", "popover", "alert"];

// Shared low-level reader over one serialized buffer (a full tree or a Patch).
function makeReader(bytes) {
  const buf = bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const decoder = new TextDecoder();

  const u8 = (pos) => view.getUint8(pos);
  const u16 = (pos) => view.getUint16(pos, true);
  const i32 = (pos) => view.getInt32(pos, true);
  const u32 = (pos) => view.getUint32(pos, true);
  const f32 = (pos) => view.getFloat32(pos, true);
  const f64 = (pos) => view.getFloat64(pos, true);

  // Absolute position of field `slot` inside the table at `table`, or 0.
  function field(table, slot) {
    const vtable = table - i32(table);
    const vtSize = u16(vtable);
    const entry = 4 + 2 * slot;
    if (entry >= vtSize) return 0;
    const offset = u16(vtable + entry);
    return offset === 0 ? 0 : table + offset;
  }
  const indirect = (pos) => pos + u32(pos);
  function string(pos) {
    const data = indirect(pos);
    const length = u32(data);
    return decoder.decode(buf.subarray(data + 4, data + 4 + length));
  }
  const color = (pos) => [f32(pos), f32(pos + 4), f32(pos + 8), f32(pos + 12)];

  function node(table) {
    const n = {};
    const kindPos = field(table, 0);
    n.k = KINDS[kindPos ? u8(kindPos) : 0] || "box";
    let pos;
    if ((pos = field(table, 1))) n.v = string(pos);
    if ((pos = field(table, 2))) n.v = f64(pos); // numeric value (slider/progress)
    if ((pos = field(table, 3))) n.id = string(pos);
    if ((pos = field(table, 4))) n.size = f64(pos);
    if ((pos = field(table, 5))) n.weight = i32(pos);
    if ((pos = field(table, 6))) n.color = color(pos);
    if ((pos = field(table, 7))) n.lines = i32(pos);
    if ((pos = field(table, 8))) n.shape = SHAPES[u8(pos)];
    if ((pos = field(table, 9))) n.fill = color(pos);
    if ((pos = field(table, 10))) n.stroke = color(pos);
    if ((pos = field(table, 11))) n.strokeWidth = f64(pos);
    if ((pos = field(table, 12))) n.axis = AXES[u8(pos)];
    else if (n.k === "stack" || n.k === "scroll") n.axis = "h";
    if ((pos = field(table, 13))) n.spacing = f64(pos);
    if ((pos = field(table, 14))) n.min = f64(pos);
    if ((pos = field(table, 15))) n.src = string(pos);
    if ((pos = field(table, 16))) n.remote = u8(pos) !== 0;
    if ((pos = field(table, 17))) n.resizable = u8(pos) !== 0;
    if ((pos = field(table, 18))) n.fit = u8(pos) !== 0;
    if ((pos = field(table, 19))) n.placeholder = string(pos);
    if ((pos = field(table, 20))) n.edit = string(pos);
    if ((pos = field(table, 21))) n.view = string(pos);
    if ((pos = field(table, 22))) {
      const vec = indirect(pos);
      const count = u32(vec);
      n.options = [];
      for (let index = 0; index < count; index += 1) {
        n.options.push(string(vec + 4 + index * 4));
      }
    }
    if ((pos = field(table, 23))) {
      const vec = indirect(pos);
      const count = u32(vec);
      n.params = {};
      for (let index = 0; index < count; index += 1) {
        const kv = indirect(vec + 4 + index * 4);
        n.params[string(field(kv, 0))] = string(field(kv, 1));
      }
    }
    if ((pos = field(table, 24))) n.growW = u8(pos) !== 0;
    if ((pos = field(table, 25))) n.growH = u8(pos) !== 0;
    if ((pos = field(table, 26))) n.alignH = ALIGN_H[u8(pos)];
    if ((pos = field(table, 27))) n.alignV = ALIGN_V[u8(pos)];
    if ((pos = field(table, 28))) {
      n.shadow = {
        color: color(pos), radius: f32(pos + 16), x: f32(pos + 20), y: f32(pos + 24),
      };
    }
    if ((pos = field(table, 29))) {
      const vec = indirect(pos);
      const count = u32(vec);
      n.padding = [];
      for (let index = 0; index < count; index += 1) {
        n.padding.push(f64(vec + 4 + index * 8));
      }
    }
    if ((pos = field(table, 30))) n.width = f64(pos);
    if ((pos = field(table, 31))) n.height = f64(pos);
    if ((pos = field(table, 32))) n.expandW = u8(pos) !== 0;
    if ((pos = field(table, 33))) n.expandH = u8(pos) !== 0;
    if ((pos = field(table, 34))) n.radius = f64(pos);
    if ((pos = field(table, 45))) n.offsetX = f64(pos);
    if ((pos = field(table, 46))) n.offsetY = f64(pos);
    if ((pos = field(table, 47))) n.scale = f64(pos);
    if ((pos = field(table, 48))) n.drag = string(pos);
    if ((pos = field(table, 49))) n.key = string(pos);
    if ((pos = field(table, 35))) n.opacity = f64(pos);
    if ((pos = field(table, 36))) n.bg = color(pos);
    if ((pos = field(table, 37))) n.gradient = string(pos);
    if ((pos = field(table, 38))) n.tap = string(pos);
    if ((pos = field(table, 39))) n.feedback = i32(pos);
    if ((pos = field(table, 40))) n.style = STYLES[u8(pos)];
    if ((pos = field(table, 41))) n.title = string(pos);
    if ((pos = field(table, 42))) n.message = string(pos);
    if ((pos = field(table, 43))) n.dismiss = string(pos);
    if ((pos = field(table, 44))) {
      const vec = indirect(pos);
      const count = u32(vec);
      n.ch = [];
      for (let index = 0; index < count; index += 1) {
        n.ch.push(node(indirect(vec + 4 + index * 4)));
      }
    }
    return n;
  }

  return { node, field, string, u8, u32, i32, indirect };
}

export function decodeTree(bytes) {
  const r = makeReader(bytes);
  return r.node(r.indirect(0));
}

// Apply a `Patch` buffer (shared/renderers/tree.fbs, the ONLY wire format the
// reactor ships) to the retained plain-object tree, returning the new root.
// Copy-on-write: only nodes on each op's path are rebuilt, so unchanged
// subtrees keep their object identity (React.memo-friendly). The first patch
// after start is a single full-tree op at "n"; `retained` is null then.
export function applyPatch(retained, bytes) {
  const r = makeReader(bytes);
  const patch = r.indirect(0);
  let root = retained;
  const opsPos = r.field(patch, 0); // Patch.ops (slot 0)
  if (opsPos) {
    const vec = r.indirect(opsPos);
    const count = r.u32(vec);
    for (let index = 0; index < count; index += 1) {
      const op = r.indirect(vec + 4 + index * 4);
      const pathPos = r.field(op, 0); // PatchOp.path (slot 0)
      if (!pathPos) continue;
      const path = r.string(pathPos);
      const orderPos = r.field(op, 3); // PatchOp.order (slot 3)
      if (orderPos) {
        const orderVec = r.indirect(orderPos);
        const order = [];
        for (let i = 0; i < r.u32(orderVec); i += 1) order.push(r.i32(orderVec + 4 + i * 4));
        const insertsPos = r.field(op, 4); // PatchOp.inserts (slot 4)
        const inserts = [];
        if (insertsPos) {
          const vec = r.indirect(insertsPos);
          for (let i = 0; i < r.u32(vec); i += 1) inserts.push(r.node(r.indirect(vec + 4 + i * 4)));
        }
        root = reorderAt(root, path, order, inserts);
        continue;
      }
      const nodePos = r.field(op, 1); // PatchOp.node (slot 1)
      if (!nodePos) continue;
      const attrsPos = r.field(op, 2); // PatchOp.attrs_only (slot 2)
      const attrsOnly = attrsPos !== 0 && r.u8(attrsPos) !== 0;
      const decoded = r.node(r.indirect(nodePos));
      root = applyOp(root, path, decoded, attrsOnly);
    }
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
