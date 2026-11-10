// Isomer's DOM renderer core: the part of React DOM 18 the web's tree
// renderer (react_renderer.js) stands on, written here so the web carries no
// React. Elements (`createElement`, `Fragment`, `Children.toArray`, `memo`),
// function components with their hooks (`useState`, `useRef`,
// `useLayoutEffect`, `useEffect`), a root that commits asynchronously as
// React's does (`createRoot`, `flushSync` for a commit now) and portals
// (`createPortal`). The DOM it makes is React DOM 18's for the same elements:
// the same attributes and properties (a controlled input's value mirrored to
// its `value` attribute, a textarea's initial value as its text, `checked`,
// `selected` and `muted` as properties, SVG's hyphenated attributes, the
// boolean ones present or absent), the same events (`onChange` on a text
// field is `input`, focus and blur bubble as `focusin` and `focusout`, wheel
// and touch listeners passive) and the same order of work in a commit (refs
// and layout effects children first, right after the DOM changes; passive
// effects in a task after it). It replaced React in 0.49 once every
// Storybook page it drew was React's, picture and DOM, at both widths
// (tools/testing/renderer_compare.sh); keep it so: a change here is held to
// the pictures before it (renderer_compare.sh's BASELINE).

const TEXT = Symbol("text");
export const Fragment = Symbol("Fragment");
const PORTAL = Symbol("portal");
const MEMO = Symbol("memo");

// --- Elements

export function createElement(type, props, ...children) {
  const own = {};
  let key = null;
  let ref = null;
  if (props) {
    for (const name in props) {
      if (name === "key") key = props.key == null ? null : String(props.key);
      else if (name === "ref") ref = props.ref == null ? null : props.ref;
      else own[name] = props[name];
    }
  }
  if (children.length === 1) own.children = children[0];
  else if (children.length > 1) own.children = children;
  return { $$iso: true, type, key, ref, props: own };
}

export function memo(type, compare = null) {
  return { $$memo: MEMO, type, compare };
}

export function createPortal(children, container, key = null) {
  return { $$iso: true, type: PORTAL, key: key == null ? null : String(key), ref: null, props: { children, container } };
}

function isElement(value) {
  return value !== null && typeof value === "object" && value.$$iso === true;
}

/// A component's children as React's Children.toArray gives them: flat,
/// holes dropped, each keyed by where it stands (".0") or its own key (".$k").
function toArray(children) {
  const out = [];
  const keyOf = (value, index) => isElement(value) && value.key != null
    ? "$" + value.key.replace(/[=:]/g, (c) => (c === "=" ? "=0" : "=2"))
    : index.toString(36);
  const walk = (value, name) => {
    if (value == null || typeof value === "boolean") return;
    if (Array.isArray(value)) {
      const prefix = name === "" ? "." : name + ":";
      value.forEach((item, index) => walk(item, prefix + keyOf(item, index)));
      return;
    }
    const path = name === "" ? "." + keyOf(value, 0) : name;
    out.push(isElement(value) ? { ...value, key: path } : value);
  };
  walk(children, "");
  return out;
}

export const Children = { toArray };

/// A host's or component's children as the reconciler takes them: holes
/// dropped, strings and numbers as text, a nested array as a fragment of its
/// own (its keys apart from its siblings', as React's).
function normalize(children) {
  const list = Array.isArray(children) ? children : [children];
  const out = [];
  for (const child of list) {
    if (child == null || typeof child === "boolean") continue;
    if (typeof child === "string" || typeof child === "number" || typeof child === "bigint") {
      out.push({ $$iso: true, type: TEXT, key: null, ref: null, props: { nodeValue: String(child) } });
    } else if (Array.isArray(child)) {
      out.push({ $$iso: true, type: Fragment, key: null, ref: null, props: { children: child } });
    } else if (isElement(child)) {
      out.push(child);
    }
  }
  return out;
}

// --- Fibers

let currentFiber = null;
let hookIndex = 0;
// What the commit runs once the DOM is changed: refs, layout effects and
// focus, in completion order (children before their parents).
let layoutQueue = [];
let passiveQueue = [];
let passiveScheduled = false;

function kindOf(type) {
  if (type === TEXT) return "text";
  if (type === Fragment) return "fragment";
  if (type === PORTAL) return "portal";
  if (typeof type === "string") return "host";
  if (type && type.$$memo === MEMO) return "memo";
  return "component";
}

function makeFiber(element, parent) {
  return {
    type: element.type, key: element.key, ref: element.ref, props: element.props,
    kind: kindOf(element.type), parent, children: [], hooks: [], dom: null,
    memoProps: null, dirty: false, mounted: false,
  };
}

function hostParent(fiber) {
  let up = fiber.parent;
  while (up && up.kind !== "host" && up.kind !== "root" && up.kind !== "portal") up = up.parent;
  return up;
}

function namespaceOf(fiber) {
  const parent = hostParent(fiber);
  if (fiber.type === "svg") return "svg";
  if (!parent) return "html";
  if (parent.kind === "root" || parent.kind === "portal") {
    const container = parent.kind === "root" ? parent.container : parent.props.container;
    return container && container.namespaceURI === SVG_NS && container.localName !== "foreignObject" ? "svg" : "html";
  }
  if (parent.ns === "svg" && parent.type !== "foreignObject") return "svg";
  return "html";
}

const SVG_NS = "http://www.w3.org/2000/svg";
const XLINK_NS = "http://www.w3.org/1999/xlink";

function render(fiber) {
  switch (fiber.kind) {
    case "text":
      if (!fiber.dom) fiber.dom = document.createTextNode(fiber.props.nodeValue);
      else if (fiber.dom.nodeValue !== fiber.props.nodeValue) fiber.dom.nodeValue = fiber.props.nodeValue;
      break;
    case "host": {
      const creating = !fiber.dom;
      if (creating) {
        fiber.ns = namespaceOf(fiber);
        fiber.dom = fiber.ns === "svg" ? document.createElementNS(SVG_NS, fiber.type) : document.createElement(fiber.type);
      }
      const previous = creating ? {} : fiber.applied || {};
      const own = hostProps(fiber, creating);
      applyProps(fiber, previous, own, creating);
      fiber.applied = own;
      reconcile(fiber, hostChildren(fiber, creating));
      syncChildren(fiber);
      afterChildren(fiber, previous, creating);
      queueRef(fiber);
      if (creating && fiber.props.autoFocus) layoutQueue.push(() => fiber.dom && fiber.dom.focus());
      break;
    }
    case "fragment":
      reconcile(fiber, normalize(fiber.props.children));
      break;
    case "portal":
      reconcile(fiber, normalize(fiber.props.children));
      syncPortal(fiber);
      break;
    case "memo": {
      const { type, compare } = fiber.type;
      if (fiber.mounted && !fiber.dirty && fiber.memoProps
          && (compare ? compare(fiber.memoProps, fiber.props) : shallowEqual(fiber.memoProps, fiber.props))) {
        fiber.props = fiber.memoProps;
        break;
      }
      fiber.memoProps = fiber.props;
      renderComponent(fiber, type);
      break;
    }
    case "component":
      renderComponent(fiber, fiber.type);
      break;
  }
  fiber.dirty = false;
  fiber.mounted = true;
}

function renderComponent(fiber, type) {
  const outer = currentFiber;
  const outerIndex = hookIndex;
  currentFiber = fiber;
  hookIndex = 0;
  fiber.effects = [];
  let output;
  try {
    output = type(fiber.props);
  } finally {
    currentFiber = outer;
    hookIndex = outerIndex;
  }
  reconcile(fiber, normalize(output));
  // This component's effects after its children's (completion order).
  for (const effect of fiber.effects) (effect.passive ? passiveQueue : layoutQueue).push(effect.run);
  fiber.effects = [];
}

function shallowEqual(a, b) {
  if (Object.is(a, b)) return true;
  const ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (const k of ka) if (!Object.prototype.hasOwnProperty.call(b, k) || !Object.is(a[k], b[k])) return false;
  return true;
}

/// The children of `fiber` matched to the old ones by key (else by place)
/// and type, rendered; the old ones not matched unmounted.
function reconcile(fiber, elements) {
  const old = fiber.children;
  const byKey = new Map();
  old.forEach((child, index) => byKey.set(child.key != null ? "$" + child.key : "#" + index, child));
  const next = [];
  elements.forEach((element, index) => {
    const slot = element.key != null ? "$" + element.key : "#" + index;
    let child = byKey.get(slot);
    if (child && child.type === element.type) {
      byKey.delete(slot);
      if (child.ref !== element.ref) {
        detachRef(child);
        child.ref = element.ref;
      }
      child.props = element.props;
    } else {
      child = makeFiber(element, fiber);
    }
    render(child);
    next.push(child);
  });
  for (const gone of byKey.values()) unmount(gone, true);
  fiber.children = next;
}

/// The DOM nodes a fiber's children stand for, in order: hosts and texts,
/// through components and fragments; a portal's go elsewhere.
function hostNodes(fiber, out = []) {
  for (const child of fiber.children) {
    if (child.kind === "host" || child.kind === "text") out.push(child.dom);
    else if (child.kind !== "portal") hostNodes(child, out);
  }
  return out;
}

/// `nodes` in `parent` in order, each moved only if it is new or out of
/// order, before the next of them (appended when last), as React places
/// them: a node someone else put in `parent` (a canvas a ref added) stays
/// where it is.
function place(parent, nodes) {
  const ours = new Set(nodes);
  const nextOurs = (node) => {
    let next = node.nextSibling;
    while (next && !ours.has(next)) next = next.nextSibling;
    return next;
  };
  for (let i = nodes.length - 1; i >= 0; i--) {
    const node = nodes[i];
    const after = i + 1 < nodes.length ? nodes[i + 1] : null;
    if (node.parentNode === parent && nextOurs(node) === after) continue;
    parent.insertBefore(node, after);
  }
}

function syncChildren(fiber) {
  if (fiber.kind === "root") {
    // A root's container is cleared at its first commit, as React's is.
    if (!fiber.cleared) {
      fiber.cleared = true;
      fiber.container.textContent = "";
    }
    place(fiber.container, hostNodes(fiber));
    return;
  }
  place(fiber.dom, hostNodes(fiber));
}

function syncPortal(fiber) {
  const container = fiber.props.container;
  if (fiber.container && fiber.container !== container) {
    for (const node of fiber.portalNodes || []) if (node.parentNode === fiber.container) fiber.container.removeChild(node);
  }
  fiber.container = container;
  const nodes = hostNodes(fiber);
  place(container, nodes);
  fiber.portalNodes = nodes;
}

/// Where a re-rendered fiber's DOM is kept in order: its nearest host, root
/// or portal above.
function syncAbove(fiber) {
  const up = hostParent(fiber);
  if (!up) return;
  if (up.kind === "portal") syncPortal(up);
  else syncChildren(up);
}

function unmount(fiber, removeDom) {
  if (fiber.kind === "host" || fiber.kind === "text") {
    if (removeDom && fiber.dom && fiber.dom.parentNode) fiber.dom.parentNode.removeChild(fiber.dom);
    removeDom = false;
  }
  if (fiber.kind === "portal") {
    for (const node of hostNodes(fiber)) if (node.parentNode) node.parentNode.removeChild(node);
  }
  for (const child of fiber.children) unmount(child, removeDom && fiber.kind !== "portal");
  for (const hook of fiber.hooks) {
    if (hook.effect && typeof hook.cleanup === "function") {
      const cleanup = hook.cleanup;
      hook.cleanup = null;
      try { cleanup(); } catch (error) { console.error(error); }
    }
  }
  if (fiber.kind === "host") detachRef(fiber);
  fiber.unmounted = true;
}

// --- Refs

function queueRef(fiber) {
  if (!fiber.ref || fiber.attachedRef === fiber.ref) return;
  const ref = fiber.ref;
  layoutQueue.push(() => {
    if (fiber.unmounted) return;
    if (typeof ref === "function") ref(fiber.dom);
    else ref.current = fiber.dom;
    fiber.attachedRef = ref;
  });
}

function detachRef(fiber) {
  const ref = fiber.attachedRef;
  if (!ref) return;
  fiber.attachedRef = null;
  if (typeof ref === "function") ref(null);
  else ref.current = null;
}

// --- Hooks

function hook(make) {
  const fiber = currentFiber;
  if (!fiber) throw new Error("a hook called outside a component");
  let found = fiber.hooks[hookIndex];
  if (!found) found = fiber.hooks[hookIndex] = make();
  hookIndex += 1;
  return [fiber, found];
}

export function useState(initial) {
  const [fiber, state] = hook(() => ({ value: typeof initial === "function" ? initial() : initial }));
  if (!state.set) {
    state.set = (action) => {
      const value = typeof action === "function" ? action(state.value) : action;
      if (Object.is(value, state.value)) return;
      state.value = value;
      markDirty(fiber);
    };
  }
  return [state.value, state.set];
}

export function useRef(initial) {
  const [, ref] = hook(() => ({ current: initial }));
  return ref;
}

function depsChanged(before, after) {
  if (!before || !after) return true;
  if (before.length !== after.length) return true;
  for (let i = 0; i < after.length; i++) if (!Object.is(before[i], after[i])) return true;
  return false;
}

function effect(create, deps, passive) {
  const [fiber, state] = hook(() => ({ effect: true, deps: undefined, cleanup: null, fresh: true }));
  if (!state.fresh && !depsChanged(state.deps, deps)) return;
  state.fresh = false;
  state.deps = deps;
  fiber.effects.push({
    passive,
    run: () => {
      if (fiber.unmounted) return;
      if (typeof state.cleanup === "function") {
        const cleanup = state.cleanup;
        state.cleanup = null;
        cleanup();
      }
      const result = create();
      state.cleanup = typeof result === "function" ? result : null;
    },
  });
}

export function useLayoutEffect(create, deps) { effect(create, deps, false); }
export function useEffect(create, deps) { effect(create, deps, true); }

// --- Scheduling and commits

const dirty = new Set();
let flushScheduled = false;
let batching = 0;
const roots = new Set();

function markDirty(fiber) {
  fiber.dirty = true;
  dirty.add(fiber);
  if (batching === 0) scheduleFlush();
}

function depth(fiber) {
  let d = 0;
  for (let up = fiber.parent; up; up = up.parent) d += 1;
  return d;
}

/// The state updates since the last commit, rendered from each top-most
/// updated fiber down, then committed (refs and layout effects now, passive
/// effects in a task after).
function flushUpdates() {
  flushPassive();
  for (const root of roots) {
    if (root.pending !== undefined) {
      const element = root.pending;
      root.pending = undefined;
      reconcile(root, element == null ? [] : normalize(element));
      syncChildren(root);
    }
  }
  while (dirty.size) {
    const fibers = [...dirty].filter((f) => !f.unmounted).sort((a, b) => depth(a) - depth(b));
    dirty.clear();
    for (const fiber of fibers) {
      if (!fiber.dirty || fiber.unmounted) continue;
      render(fiber);
      syncAbove(fiber);
    }
  }
  commit();
}

function commit() {
  while (layoutQueue.length) {
    const queue = layoutQueue;
    layoutQueue = [];
    for (const run of queue) {
      try { run(); } catch (error) { console.error(error); }
    }
    // A layout effect's state update renders before this commit ends, as
    // React's do.
    if (dirty.size) {
      const fibers = [...dirty].filter((f) => !f.unmounted).sort((a, b) => depth(a) - depth(b));
      dirty.clear();
      for (const fiber of fibers) {
        if (!fiber.dirty || fiber.unmounted) continue;
        render(fiber);
        syncAbove(fiber);
      }
    }
  }
  if (passiveQueue.length && !passiveScheduled) {
    passiveScheduled = true;
    passiveChannel.port2.postMessage(null);
  }
}

function flushPassive() {
  passiveScheduled = false;
  if (!passiveQueue.length) return;
  const queue = passiveQueue;
  passiveQueue = [];
  batching += 1;
  try {
    for (const run of queue) {
      try { run(); } catch (error) { console.error(error); }
    }
  } finally {
    batching -= 1;
  }
}

const passiveChannel = new MessageChannel();
passiveChannel.port1.onmessage = () => {
  if (!passiveScheduled) return;
  flushPassive();
  if (dirty.size) scheduleFlush();
};

const flushChannel = new MessageChannel();
flushChannel.port1.onmessage = () => {
  if (!flushScheduled) return;
  flushScheduled = false;
  flushUpdates();
};

function scheduleFlush() {
  if (flushScheduled) return;
  flushScheduled = true;
  flushChannel.port2.postMessage(null);
}

/// `fn`, then everything it asked for committed before this returns.
export function flushSync(fn) {
  batching += 1;
  let result;
  try {
    result = fn ? fn() : undefined;
  } finally {
    batching -= 1;
  }
  flushScheduled = false;
  flushUpdates();
  return result;
}

/// A handler's updates, rendered as it returns (React flushes an event's
/// updates at its end).
function batched(fn) {
  batching += 1;
  try {
    fn();
  } finally {
    batching -= 1;
  }
  if (batching === 0 && (dirty.size || [...roots].some((r) => r.pending !== undefined))) {
    flushScheduled = false;
    flushUpdates();
  }
}

export function createRoot(container) {
  const root = { kind: "root", type: null, container, children: [], parent: null, hooks: [], pending: undefined };
  roots.add(root);
  return {
    render(element) {
      root.pending = element;
      if (batching === 0) scheduleFlush();
    },
    unmount() {
      for (const child of root.children) unmount(child, true);
      root.children = [];
      roots.delete(root);
    },
  };
}

// --- Host properties, as React DOM 18 sets them

// Numbers given these CSS properties stay unitless; others take "px".
const UNITLESS = new Set([
  "animationIterationCount", "aspectRatio", "borderImageOutset", "borderImageSlice", "borderImageWidth",
  "boxFlex", "boxFlexGroup", "boxOrdinalGroup", "columnCount", "columns", "flex", "flexGrow", "flexPositive",
  "flexShrink", "flexNegative", "flexOrder", "gridArea", "gridRow", "gridRowEnd", "gridRowSpan", "gridRowStart",
  "gridColumn", "gridColumnEnd", "gridColumnSpan", "gridColumnStart", "fontWeight", "lineClamp", "lineHeight",
  "opacity", "order", "orphans", "tabSize", "widows", "zIndex", "zoom", "fillOpacity", "floodOpacity",
  "stopOpacity", "strokeDasharray", "strokeDashoffset", "strokeMiterlimit", "strokeOpacity", "strokeWidth",
]);
for (const name of [...UNITLESS]) for (const prefix of ["Webkit", "ms", "Moz", "O"]) UNITLESS.add(prefix + name[0].toUpperCase() + name.slice(1));

function styleValue(name, value) {
  if (value == null || typeof value === "boolean" || value === "") return "";
  if (typeof value === "number" && value !== 0 && !UNITLESS.has(name) && !name.startsWith("--")) return value + "px";
  return ("" + value).trim();
}

function setStyle(style, name, value) {
  const text = styleValue(name, value);
  if (name.startsWith("--")) style.setProperty(name, text);
  else if (name === "float") style.cssFloat = text;
  else style[name] = text;
}

// React DOM's SVG attributes with a hyphenated name.
const SVG_HYPHENATED = new Set([
  "accentHeight", "alignmentBaseline", "arabicForm", "baselineShift", "capHeight", "clipPath", "clipRule",
  "colorInterpolation", "colorInterpolationFilters", "colorProfile", "colorRendering", "dominantBaseline",
  "enableBackground", "fillOpacity", "fillRule", "floodColor", "floodOpacity", "fontFamily", "fontSize",
  "fontSizeAdjust", "fontStretch", "fontStyle", "fontVariant", "fontWeight", "glyphName",
  "glyphOrientationHorizontal", "glyphOrientationVertical", "horizAdvX", "horizOriginX", "imageRendering",
  "letterSpacing", "lightingColor", "markerEnd", "markerMid", "markerStart", "overlinePosition",
  "overlineThickness", "paintOrder", "panose1", "pointerEvents", "renderingIntent", "shapeRendering", "stopColor",
  "stopOpacity", "strikethroughPosition", "strikethroughThickness", "strokeDasharray", "strokeDashoffset",
  "strokeLinecap", "strokeLinejoin", "strokeMiterlimit", "strokeOpacity", "strokeWidth", "textAnchor",
  "textDecoration", "textRendering", "underlinePosition", "underlineThickness", "unicodeBidi", "unicodeRange",
  "unitsPerEm", "vAlphabetic", "vHanging", "vIdeographic", "vMathematical", "vectorEffect", "vertAdvY",
  "vertOriginX", "vertOriginY", "wordSpacing", "writingMode", "xHeight",
]);
const ALIASES = { className: "class", htmlFor: "for", acceptCharset: "accept-charset", httpEquiv: "http-equiv" };
// Attributes present or absent.
const BOOLEAN = new Set([
  "allowFullScreen", "async", "autoPlay", "controls", "default", "defer", "disabled", "disablePictureInPicture",
  "disableRemotePlayback", "formNoValidate", "hidden", "loop", "noModule", "noValidate", "open", "playsInline",
  "readOnly", "required", "reversed", "scoped", "seamless", "itemScope",
]);
// Attributes "true" or "false".
const BOOLEANISH = new Set(["contentEditable", "draggable", "spellCheck", "value"]);
// Set as properties, never attributes.
const PROPERTIES = new Set(["checked", "multiple", "muted", "selected"]);
// Not attributes at all.
const RESERVED = new Set(["children", "dangerouslySetInnerHTML", "suppressContentEditableWarning",
  "suppressHydrationWarning", "autoFocus", "defaultValue", "defaultChecked", "innerHTML", "style"]);

/// What of a host's props go onto the element, as React DOM's wrappers
/// shape them: an input's and a textarea's value and checked handled after
/// its attributes (afterChildren); a textarea's text its initial value.
function hostProps(fiber, creating) {
  const props = fiber.props;
  if (fiber.type === "input" || fiber.type === "textarea" || fiber.type === "select") {
    const own = { ...props };
    delete own.value;
    delete own.checked;
    return own;
  }
  return props;
}

function hostChildren(fiber, creating) {
  // A textarea's text is its initial value, set once (afterChildren).
  if (fiber.type === "textarea") return [];
  const children = fiber.props.children;
  // A lone empty string is no text node (React sets textContent to it).
  if (children === "") return [];
  return normalize(children);
}

function attributeName(fiber, name) {
  if (ALIASES[name]) return ALIASES[name];
  // React maps these whatever the element (an HTML one too).
  if (SVG_HYPHENATED.has(name)) return name.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
  return name;
}

function applyProps(fiber, previous, next, creating) {
  const dom = fiber.dom;
  for (const name in previous) {
    if (name in next && next[name] != null) continue;
    removeProp(fiber, name, previous[name]);
  }
  for (const name in next) {
    const value = next[name];
    if (!creating && previous[name] === value && name !== "style") continue;
    if (value == null) {
      if (name in previous) removeProp(fiber, name, previous[name]);
      continue;
    }
    if (name === "style") {
      const before = previous.style || {};
      const after = value || {};
      if (typeof after === "object") {
        for (const key in before) if (!(key in after) || after[key] == null) setStyle(dom.style, key, "");
        for (const key in after) if (creating || before[key] !== after[key]) setStyle(dom.style, key, after[key]);
      }
      continue;
    }
    if (RESERVED.has(name)) continue;
    if (name.length > 2 && name[0] === "o" && name[1] === "n" && name[2] >= "A" && name[2] <= "Z") {
      setHandler(fiber, name, value);
      continue;
    }
    setAttribute(fiber, name, value);
  }
  void dom;
}

function setAttribute(fiber, name, value) {
  const dom = fiber.dom;
  if (PROPERTIES.has(name)) {
    dom[name] = !!value;
    return;
  }
  if (name === "xlinkHref") {
    dom.setAttributeNS(XLINK_NS, "xlink:href", String(value));
    return;
  }
  const attribute = attributeName(fiber, name);
  const data = name.startsWith("data-") || name.startsWith("aria-");
  if (typeof value === "function" || typeof value === "symbol") {
    dom.removeAttribute(attribute);
    return;
  }
  if (BOOLEAN.has(name)) {
    if (value) dom.setAttribute(attribute, "");
    else dom.removeAttribute(attribute);
    return;
  }
  if (BOOLEANISH.has(name) && typeof value === "boolean") {
    dom.setAttribute(attribute, value ? "true" : "false");
    return;
  }
  if (typeof value === "boolean" && !data) {
    // React drops a boolean given to an attribute that takes a string.
    dom.removeAttribute(attribute);
    return;
  }
  dom.setAttribute(attribute, String(value));
}

function removeProp(fiber, name, value) {
  const dom = fiber.dom;
  if (name === "style") {
    for (const key in value || {}) setStyle(dom.style, key, "");
    return;
  }
  if (RESERVED.has(name)) return;
  if (name.length > 2 && name[0] === "o" && name[1] === "n" && name[2] >= "A" && name[2] <= "Z") {
    setHandler(fiber, name, null);
    return;
  }
  if (PROPERTIES.has(name)) {
    dom[name] = false;
    return;
  }
  if (name === "xlinkHref") {
    dom.removeAttributeNS(XLINK_NS, "href");
    return;
  }
  dom.removeAttribute(attributeName(fiber, name));
}

/// An input's, a textarea's and a select's value and checked, as React DOM's
/// wrappers set them once its attributes and children are.
function afterChildren(fiber, previous, creating) {
  const dom = fiber.dom;
  const props = fiber.props;
  const has = (name) => Object.prototype.hasOwnProperty.call(props, name);
  const string = (value) => (value == null || typeof value === "function" || typeof value === "symbol" || typeof value === "boolean" ? null : String(value));
  if (fiber.type === "input") {
    const type = props.type;
    if (creating) {
      fiber.initialValue = string(props.value != null ? props.value : props.defaultValue) ?? "";
      if (props.checked != null) dom.checked = !!props.checked;
      if (has("value") || has("defaultValue")) {
        if ((type === "submit" || type === "reset") && props.value == null) return;
        if (fiber.initialValue !== dom.value) dom.value = fiber.initialValue;
        dom.defaultValue = fiber.initialValue;
      }
      const name = dom.name;
      if (name !== "") dom.name = "";
      dom.defaultChecked = !dom.defaultChecked;
      dom.defaultChecked = !!(props.checked != null ? props.checked : props.defaultChecked);
      if (name !== "") dom.name = name;
      return;
    }
    updateInput(fiber);
  } else if (fiber.type === "textarea") {
    if (creating) {
      let initial = props.value != null ? props.value : props.defaultValue != null ? props.defaultValue : props.children;
      if (Array.isArray(initial)) initial = initial[0];
      fiber.initialValue = string(initial) ?? "";
      dom.textContent = fiber.initialValue;
      if (dom.textContent === fiber.initialValue && fiber.initialValue !== "") dom.value = fiber.initialValue;
      return;
    }
    updateTextarea(fiber);
  } else if (fiber.type === "select") {
    if (creating) {
      dom.multiple = !!props.multiple;
      if (props.value != null) selectOptions(dom, !!props.multiple, props.value, false);
      else if (props.defaultValue != null) selectOptions(dom, !!props.multiple, props.defaultValue, true);
    } else if (props.value != null) {
      selectOptions(dom, !!props.multiple, props.value, false);
    }
  } else if (fiber.type === "option" && creating && props.value != null) {
    dom.setAttribute("value", String(props.value));
  }
  void previous;
}

// React DOM's ReactDOMInput.updateWrapper.
function updateInput(fiber) {
  const dom = fiber.dom;
  const props = fiber.props;
  const has = (name) => Object.prototype.hasOwnProperty.call(props, name);
  if (props.checked != null) dom.checked = !!props.checked;
  const value = props.value == null || typeof props.value === "boolean" ? null : String(props.value);
  const type = props.type;
  if (value != null) {
    if (type === "number") {
      if ((value === "0" && dom.value === "") || dom.value != value) dom.value = value;
    } else if (dom.value !== value) {
      dom.value = value;
    }
  } else if (type === "submit" || type === "reset") {
    dom.removeAttribute("value");
    return;
  }
  const setDefault = (wanted) => {
    if (type === "number" && dom.ownerDocument.activeElement === dom) return;
    if (wanted == null) dom.defaultValue = fiber.initialValue;
    else if (dom.defaultValue !== wanted) dom.defaultValue = wanted;
  };
  if (has("value")) setDefault(value);
  else if (has("defaultValue")) setDefault(props.defaultValue == null ? null : String(props.defaultValue));
  if (props.checked == null && props.defaultChecked != null) dom.defaultChecked = !!props.defaultChecked;
}

// React DOM's ReactDOMTextarea.updateWrapper.
function updateTextarea(fiber) {
  const dom = fiber.dom;
  const props = fiber.props;
  if (props.value != null) {
    const value = String(props.value);
    if (value !== dom.value) dom.value = value;
    if (props.defaultValue == null && dom.defaultValue !== value) dom.defaultValue = value;
  }
  if (props.defaultValue != null) dom.defaultValue = String(props.defaultValue);
}

// React DOM's ReactDOMSelect.updateOptions.
function selectOptions(dom, multiple, value, setDefaultSelected) {
  const options = dom.options;
  if (multiple) {
    const wanted = new Set((value || []).map((v) => "$" + v));
    for (const option of options) {
      const selected = wanted.has("$" + option.value);
      if (option.selected !== selected) option.selected = selected;
      if (selected && setDefaultSelected) option.defaultSelected = true;
    }
    return;
  }
  const wanted = String(value);
  let fallback = null;
  for (const option of options) {
    if (option.value === wanted) {
      option.selected = true;
      if (setDefaultSelected) option.defaultSelected = true;
      return;
    }
    if (fallback === null && !option.disabled) fallback = option;
  }
  if (fallback !== null) fallback.selected = true;
}

// --- Events

// React's names and the DOM's events they listen to.
const EVENTS = {
  onClick: "click", onDoubleClick: "dblclick", onContextMenu: "contextmenu", onMouseDown: "mousedown",
  onMouseUp: "mouseup", onMouseMove: "mousemove", onMouseEnter: "mouseenter", onMouseLeave: "mouseleave",
  onMouseOver: "mouseover", onMouseOut: "mouseout", onPointerDown: "pointerdown", onPointerUp: "pointerup",
  onPointerMove: "pointermove", onPointerCancel: "pointercancel", onPointerEnter: "pointerenter",
  onPointerLeave: "pointerleave", onPointerOver: "pointerover", onPointerOut: "pointerout",
  onGotPointerCapture: "gotpointercapture", onLostPointerCapture: "lostpointercapture",
  onTouchStart: "touchstart", onTouchMove: "touchmove", onTouchEnd: "touchend", onTouchCancel: "touchcancel",
  onWheel: "wheel", onScroll: "scroll", onKeyDown: "keydown", onKeyUp: "keyup", onKeyPress: "keypress",
  onFocus: "focusin", onBlur: "focusout", onInput: "input", onSubmit: "submit", onReset: "reset",
  onInvalid: "invalid", onDrag: "drag", onDragStart: "dragstart", onDragEnd: "dragend", onDragEnter: "dragenter",
  onDragLeave: "dragleave", onDragOver: "dragover", onDrop: "drop", onLoad: "load", onError: "error",
  onCompositionStart: "compositionstart", onCompositionEnd: "compositionend", onCompositionUpdate: "compositionupdate",
  onCopy: "copy", onCut: "cut", onPaste: "paste", onPlay: "play", onPause: "pause", onEnded: "ended",
  onTimeUpdate: "timeupdate", onLoadedMetadata: "loadedmetadata", onLoadedData: "loadeddata",
  onCanPlay: "canplay", onVolumeChange: "volumechange", onAnimationEnd: "animationend",
  onTransitionEnd: "transitionend", onToggle: "toggle",
};
// Listened to passively, as React registers them.
const PASSIVE = new Set(["touchstart", "touchmove", "wheel"]);

function nativeEventsFor(fiber, name) {
  if (name === "onChange") {
    const type = fiber.type === "input" ? fiber.props.type : null;
    if (fiber.type === "select" || type === "file") return ["change"];
    if (type === "checkbox" || type === "radio") return ["click"];
    if (fiber.type === "input" || fiber.type === "textarea") return ["input"];
    return ["change"];
  }
  // A text field's selection, after whatever may have moved it (React's
  // SelectEventPlugin), reported when it changed.
  if (name === "onSelect") return ["focusin", "focusout", "mouseup", "dragend", "selectionchange", "keydown", "keyup"];
  const event = EVENTS[name];
  return event ? [event] : [];
}

function setHandler(fiber, name, handler) {
  const dom = fiber.dom;
  const handlers = dom.__isoHandlers || (dom.__isoHandlers = {});
  const listening = dom.__isoListening || (dom.__isoListening = new Set());
  if (handler == null) {
    delete handlers[name];
    return;
  }
  handlers[name] = handler;
  for (const type of nativeEventsFor(fiber, name)) {
    if (listening.has(type)) continue;
    listening.add(type);
    dom.addEventListener(type, (event) => dispatch(fiber, dom, type, event), PASSIVE.has(type) ? { passive: true } : false);
  }
}

function dispatch(fiber, dom, type, event) {
  const handlers = dom.__isoHandlers || {};
  if (!("nativeEvent" in event)) {
    try {
      Object.defineProperty(event, "nativeEvent", { value: event });
      Object.defineProperty(event, "persist", { value: () => {} });
    } catch (_) { /* a frozen event: its own properties do */ }
  }
  let changed = false;
  batched(() => {
    for (const name in handlers) {
      if (!nativeEventsFor(fiber, name).includes(type)) continue;
      if (name === "onSelect") {
        if (dom.ownerDocument.activeElement !== dom || !("selectionStart" in dom)) continue;
        const range = `${dom.selectionStart},${dom.selectionEnd}`;
        if (range === fiber.lastSelection) continue;
        fiber.lastSelection = range;
        handlers[name]({ type: "select", target: dom, currentTarget: dom, nativeEvent: event,
          preventDefault() {}, stopPropagation() {}, persist() {} });
        continue;
      }
      if (name === "onChange") changed = true;
      handlers[name](event);
    }
  });
  // A controlled field shows its props: React puts them back when a
  // change didn't take.
  if (changed && !fiber.unmounted) {
    if (fiber.type === "input") updateInput(fiber);
    else if (fiber.type === "textarea") updateTextarea(fiber);
    else if (fiber.type === "select" && fiber.props.value != null) selectOptions(dom, !!fiber.props.multiple, fiber.props.value, false);
  }
}

// What react_renderer.js imports, under React's names.
export const React = { createElement, Fragment, Children, memo, useState, useRef, useLayoutEffect, useEffect };
export const ReactDOM = { createRoot, createPortal, flushSync };
