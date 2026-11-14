// A remote session's messages (shared/wire/session.proto) as the web writes
// and reads them: the thin client's (remote.js: ClientMessage out,
// ServerMessage in) and the page that serves a session (session_host.js, an
// app in web-view mode: ClientMessage in, ServerMessage out); the gateway's
// tests too. Hand-written against protobuf's wire format, as flat_tree.js
// is: field numbers MUST match session.proto's.

import { makeReader } from "./flat_tree.js";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

// A protobuf message being written: fields in the order they are added. Its
// small parts (tags, lengths, numbers) gather in an array; a length-delimited
// field's bytes are kept as a copy of their own (a patch is a view of the
// guest's memory, which its next frame rewrites) and joined once, at the end.
function writer() {
  const chunks = [];
  let small = [];
  const flush = () => {
    if (small.length) {
      chunks.push(Uint8Array.from(small));
      small = [];
    }
  };
  const varint = (value) => {
    let n = value >>> 0;
    while (n > 0x7f) {
      small.push((n & 0x7f) | 0x80);
      n >>>= 7;
    }
    small.push(n);
  };
  const tag = (field, type) => varint((field << 3) | type);
  const self = {
    bytes() {
      flush();
      if (chunks.length === 1) return chunks[0];
      const out = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
      let at = 0;
      for (const chunk of chunks) {
        out.set(chunk, at);
        at += chunk.length;
      }
      return out;
    },
    uint(field, value) { tag(field, 0); varint(value); return self; },
    bool(field, value) { tag(field, 0); varint(value ? 1 : 0); return self; },
    double(field, value) {
      tag(field, 1);
      const view = new DataView(new ArrayBuffer(8));
      view.setFloat64(0, value, true);
      for (let i = 0; i < 8; i++) small.push(view.getUint8(i));
      return self;
    },
    data(field, data) {
      tag(field, 2);
      varint(data.length);
      flush();
      chunks.push(data instanceof Uint8Array ? data.slice() : Uint8Array.from(data));
      return self;
    },
    string(field, text) { return self.data(field, textEncoder.encode(text)); },
    message(field, sub) { return self.data(field, sub.bytes()); },
  };
  return self;
}

const size = (width, height) => writer().double(1, width).double(2, height);
const event = (id, value) => writer().string(1, id).string(2, value);

// session.proto's ClientMessage, one per field of its oneof.
export const clientMessage = {
  start({ width, height, displayScale, dark, environment = {}, renderer = "dom" }) {
    const start = writer().message(1, size(width, height)).double(2, displayScale).bool(3, dark);
    for (const [key, value] of Object.entries(environment)) {
      start.message(4, writer().string(1, key).string(2, String(value)));
    }
    start.string(5, renderer);
    return writer().message(1, start).bytes();
  },
  resize: (width, height) => writer().message(2, size(width, height)).bytes(),
  event: (id, value) => writer().message(3, event(id, value)).bytes(),
  key: (id, value) => writer().message(4, event(id, value)).bytes(),
  dark: (dark) => writer().bool(8, dark).bytes(),
  displayScale: (scale) => writer().double(9, scale).bytes(),
  // 0 active, 1 inactive, 2 background (session.proto's ScenePhase).
  scenePhase: (phase) => writer().uint(10, phase).bytes(),
  openURL: (url) => writer().string(11, url).bytes(),
  back: () => writer().message(12, writer()).bytes(),
};

// session.proto's ServerMessage, one per field of its oneof: what a page
// serving a session (session_host.js) sends its head.
export const serverMessage = {
  // The patch's bytes are a tree.proto Patch, the guest's renderTree.
  patch: (bytes) => writer().data(1, bytes).bytes(),
  command: (key, value) => writer().message(2, writer().string(1, key).string(2, value)).bytes(),
  image: (source, bytes) => writer().message(3, writer().string(1, source).data(2, bytes)).bytes(),
  openURL: (url) => writer().string(4, url).bytes(),
  dark: (dark) => writer().bool(5, dark).bytes(),
  textInput({ text, x, y, width, height, fontSize }) {
    const request = writer().string(1, text).double(2, x).double(3, y)
      .double(4, width).double(5, height).double(6, fontSize);
    return writer().message(6, request).bytes();
  },
  endTextInput: () => writer().message(7, writer()).bytes(),
  log: (line) => writer().string(8, line).bytes(),
};

// A sub-message's fields, by `names` (field number to name and kind: "string",
// "bytes", "double", "uint", "bool").
function fields(bytes, [from, to], names) {
  const r = makeReader(bytes, from, to);
  const out = {};
  while (!r.done()) {
    const [field, type] = r.tag();
    const entry = names[field];
    if (!entry) { r.skip(type); continue; }
    const [name, kind] = entry;
    if (kind === "string" && type === 2) out[name] = r.string();
    else if (kind === "bytes" && type === 2) {
      const [start, end] = r.span();
      out[name] = bytes.subarray(start, end);
    } else if (kind === "double" && type === 1) out[name] = r.double();
    else if (kind === "uint" && type === 0) out[name] = r.uint();
    else if (kind === "bool" && type === 0) out[name] = r.bool();
    else r.skip(type);
  }
  return out;
}

const SIZE = { 1: ["width", "double"], 2: ["height", "double"] };
const EVENT = { 1: ["id", "string"], 2: ["value", "string"] };

// session.proto's ClientMessage, as `{ start: {width, height, displayScale,
// dark, environment, renderer} }`, `{ resize: {width, height} }`,
// `{ event: {id, value} }`, `{ key }`, `{ pointer: {phase, x, y} }`,
// `{ wheel }`, `{ text: {change, text} }`, `{ dark }`, `{ displayScale }`,
// `{ scenePhase }` (0 active, 1 inactive, 2 background), `{ openURL }`,
// `{ back: true }`. A proto3 oneof's member is written even at its default
// (`dark: false`, `scenePhase: 0`), so each is read as present.
export function readClientMessage(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  const r = makeReader(bytes);
  const message = {};
  while (!r.done()) {
    const [field, type] = r.tag();
    if (field === 1 && type === 2) {
      const [from, to] = r.span();
      const start = { width: 0, height: 0, displayScale: 0, dark: false, environment: {}, renderer: "" };
      const s = makeReader(bytes, from, to);
      while (!s.done()) {
        const [inner, kind] = s.tag();
        if (inner === 1 && kind === 2) Object.assign(start, fields(bytes, s.span(), SIZE));
        else if (inner === 2 && kind === 1) start.displayScale = s.double();
        else if (inner === 3 && kind === 0) start.dark = s.bool();
        else if (inner === 4 && kind === 2) {
          const { key = "", value = "" } = fields(bytes, s.span(), { 1: ["key", "string"], 2: ["value", "string"] });
          start.environment[key] = value;
        } else if (inner === 5 && kind === 2) start.renderer = s.string();
        else s.skip(kind);
      }
      message.start = start;
    } else if (field === 2 && type === 2) message.resize = { width: 0, height: 0, ...fields(bytes, r.span(), SIZE) };
    else if (field === 3 && type === 2) message.event = { id: "", value: "", ...fields(bytes, r.span(), EVENT) };
    else if (field === 4 && type === 2) message.key = { id: "", value: "", ...fields(bytes, r.span(), EVENT) };
    else if (field === 5 && type === 2) {
      message.pointer = { phase: 0, x: 0, y: 0,
        ...fields(bytes, r.span(), { 1: ["phase", "uint"], 2: ["x", "double"], 3: ["y", "double"] }) };
    } else if (field === 6 && type === 2) {
      message.wheel = { x: 0, y: 0, deltaX: 0, deltaY: 0, ...fields(bytes, r.span(),
        { 1: ["x", "double"], 2: ["y", "double"], 3: ["deltaX", "double"], 4: ["deltaY", "double"] }) };
    } else if (field === 7 && type === 2) {
      // 0 edited, 1 submitted, 2 ended (session.proto's TextInput.Change).
      message.text = { change: 0, text: "", ...fields(bytes, r.span(), { 1: ["change", "uint"], 2: ["text", "string"] }) };
    } else if (field === 8 && type === 0) message.dark = r.bool();
    else if (field === 9 && type === 1) message.displayScale = r.double();
    else if (field === 10 && type === 0) message.scenePhase = r.uint();
    else if (field === 11 && type === 2) message.openURL = r.string();
    else if (field === 12 && type === 2) { r.skip(type); message.back = true; }
    else r.skip(type);
  }
  return message;
}

// session.proto's ServerMessage, as `{ patch }`, `{ command: {key, value} }`,
// `{ image: {source, bytes} }`, `{ openURL }`, `{ dark }`, `{ log }`, …
export function readServerMessage(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  const r = makeReader(bytes);
  const pair = ([from, to], names) => {
    const sub = makeReader(bytes, from, to);
    const out = {};
    while (!sub.done()) {
      const [field, type] = sub.tag();
      const name = names[field];
      if (name && type === 2) {
        const span = sub.span();
        out[name] = name === "bytes" ? bytes.subarray(span[0], span[1]) : textDecoder.decode(bytes.subarray(span[0], span[1]));
      } else sub.skip(type);
    }
    return out;
  };
  const message = {};
  while (!r.done()) {
    const [field, type] = r.tag();
    if (field === 1 && type === 2) {
      const [from, to] = r.span();
      message.patch = bytes.subarray(from, to);
    } else if (field === 2 && type === 2) message.command = pair(r.span(), { 1: "key", 2: "value" });
    else if (field === 3 && type === 2) message.image = pair(r.span(), { 1: "source", 2: "bytes" });
    else if (field === 4 && type === 2) message.openURL = r.string();
    else if (field === 5 && type === 0) message.dark = r.bool();
    else if (field === 6 && type === 2) { r.skip(type); message.textInput = true; }
    else if (field === 7 && type === 2) { r.skip(type); message.endTextInput = true; }
    else if (field === 8 && type === 2) message.log = r.string();
    else r.skip(type);
  }
  return message;
}

// Bytes as base64 and back: how a transport that carries strings alone (a
// web view's message channel, `callAsyncJavaScript`'s arguments) carries a
// message. In slices, so a whole tree's patch never meets the argument limit
// of `String.fromCharCode`.
export function toBase64(bytes) {
  let text = "";
  for (let at = 0; at < bytes.length; at += 0x8000) {
    text += String.fromCharCode.apply(null, bytes.subarray(at, at + 0x8000));
  }
  return btoa(text);
}

export function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
