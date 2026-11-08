// A remote session's messages (shared/wire/session.proto) as the web's
// thin client writes and reads them (remote.js; the gateway's tests too).
// Hand-written against protobuf's wire format, as flat_tree.js is: field
// numbers MUST match session.proto's.

import { makeReader } from "./flat_tree.js";

const textEncoder = new TextEncoder();

// A protobuf message being written: fields in the order they are added.
function writer() {
  const bytes = [];
  const varint = (value) => {
    let n = value >>> 0;
    while (n > 0x7f) {
      bytes.push((n & 0x7f) | 0x80);
      n >>>= 7;
    }
    bytes.push(n);
  };
  const tag = (field, type) => varint((field << 3) | type);
  const self = {
    bytes: () => Uint8Array.from(bytes),
    uint(field, value) { tag(field, 0); varint(value); return self; },
    bool(field, value) { tag(field, 0); varint(value ? 1 : 0); return self; },
    double(field, value) {
      tag(field, 1);
      const view = new DataView(new ArrayBuffer(8));
      view.setFloat64(0, value, true);
      for (let i = 0; i < 8; i++) bytes.push(view.getUint8(i));
      return self;
    },
    data(field, data) {
      tag(field, 2);
      varint(data.length);
      for (const byte of data) bytes.push(byte);
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
  start({ width, height, displayScale, dark, environment = {}, renderer = "react" }) {
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
        out[name] = name === "bytes" ? bytes.subarray(span[0], span[1]) : new TextDecoder().decode(bytes.subarray(span[0], span[1]));
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
