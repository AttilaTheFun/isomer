// swift_ffi_runtime — the hand-written JavaScript half of the bridge
// runtime, shared by every generated module (an ES module; its types are in
// swift_ffi_runtime.d.ts beside it). `js_swift_wasm_library` stages this
// file next to the generated bindings, which import from
// "./swift_ffi_runtime.js"; multiple bridges in one directory share the one
// copy. The generated module keeps only the per-Swift-module pieces
// (wrapper classes, marshaling, the wasm import table, `load()`).
//
// Ownership follows the swift-java model: wrapper objects own a +1 handle
// to the Swift instance. Release deterministically with `close()` (or a
// `using` declaration); the FinalizationRegistry backstop releases leaked
// wrappers after they are garbage collected.
//
// It was TypeScript, compiled by tsc, until 0.54: this is what tsc made of
// it (ES2022, class fields defined), kept by hand, so a page runs the same
// code it ran then.

export class Runtime {
  memory;
  exports;

  constructor(exports) {
    this.exports = exports;
    this.memory = exports.memory;
  }

  call(name, ...args) {
    const fn = this.exports[name];
    return fn(...args);
  }

  /** True when the reactor exports `name` (e.g. an interface's register
   * entry point). */
  has(name) {
    return typeof this.exports[name] === "function";
  }
}

export const encoder = new TextEncoder();
export const decoder = new TextDecoder();

export function stageBytes(runtime, bytes) {
  if (bytes.length === 0) {
    return { ptr: 0, len: 0, drop() {} };
  }
  const ptr = runtime.call("swift_ffi_alloc", bytes.length);
  new Uint8Array(runtime.memory.buffer, ptr, bytes.length).set(bytes);
  return { ptr, len: bytes.length, drop: () => runtime.call("swift_ffi_dealloc", ptr) };
}

export function stageString(runtime, value) {
  return stageBytes(runtime, encoder.encode(value));
}

export function takeBytes(runtime, handle) {
  const len = runtime.call("swift_ffi_string_len", handle);
  let result = new Uint8Array(0);
  if (len > 0) {
    const ptr = runtime.call("swift_ffi_alloc", len);
    runtime.call("swift_ffi_string_copy", handle, ptr);
    result = new Uint8Array(runtime.memory.buffer, ptr, len).slice();
    runtime.call("swift_ffi_dealloc", ptr);
  }
  runtime.call("swift_ffi_string_release", handle);
  return result;
}

export function takeString(runtime, handle) {
  return decoder.decode(takeBytes(runtime, handle));
}

/** Releases leaked Swift-owned wrappers after garbage collection. */
export const registry = new FinalizationRegistry((release) => release());

/** A Swift error surfaced across the bridge (message only). */
export class SwiftError extends Error {
}

// In-flight async calls, keyed by call id, awaiting the fixed
// `swift_ffi.async_complete` import (the blob decodes per-call).
export const pendingCalls = new Map();
let callId = 0;

export function nextCallId() {
  callId += 1;
  return callId;
}

/** An ERROR blob carrying `message` (a dispatcher's failure answer). */
export function encodeError(message) {
  const w = new BlobWriter();
  w.header(Tags.error, 0);
  const bytes = encoder.encode(message);
  w.i64(BigInt(bytes.length)).bytes(bytes);
  return w.data();
}

/** Delivers a host implementation's answer to an in-flight async interface
 * call: stages `blob` and calls the guest's fixed `swift_ffi_async_resume`
 * export (the resumed Swift task runs on the next microtask pump). */
export function resumeAsync(runtime, callId, blob) {
  const staged = stageBytes(runtime, blob);
  runtime.call("swift_ffi_async_resume", callId, staged.ptr, staged.len);
  staged.drop();
}

// Consumer implementations passed into Swift are parked here as ordinal
// DISPATCHERS (closures, foreign interface objects, and injected
// dependencies all cross the one `swift_ffi.closure_invoke` channel);
// Swift's proxy releases its entry via `foreign_release` when ARC drops it.
export const foreignObjects = new Map();
let foreignId = 0;

export function registerForeign(dispatcher) {
  foreignId += 1;
  foreignObjects.set(foreignId, dispatcher);
  return foreignId;
}

const WASI_SUCCESS = 0;
const WASI_EBADF = 8;
const WASI_ENOSYS = 52;

/** The minimal WASI surface a swift_ffi reactor touches (it performs no
 * I/O of its own). Randomness is REAL (`crypto.getRandomValues` — guest
 * crypto bottoms out in `random_get`, so it must never be a toy PRNG),
 * clocks are real (Foundation's `__CFDateInitialize` traps on a failing
 * clock), and guest stdout/stderr reach the console. `overrides` merges over
 * the built-ins, so a host can extend or replace any call without forking;
 * given as a function, it gets the memory accessor (for calls that read or
 * write guest memory, possibly during `_initialize`) and the built-ins, so
 * an override can hand back what it doesn't own (a file system's `fd_write`
 * passes stdout and stderr on). */
export function wasiShim(getMemory, overridesOrFactory = {}) {
  const view = () => new DataView(getMemory().buffer);
  // Guest stdout/stderr, buffered to newlines per fd.
  const lineBuffers = new Map();
  const textDecoder = new TextDecoder();
  const emit = (fd, chunk) => {
    let buffered = (lineBuffers.get(fd) ?? "") + chunk;
    let newline = buffered.lastIndexOf("\n");
    if (newline >= 0) {
      const lines = buffered.slice(0, newline);
      (fd === 2 ? console.error : console.log)("[wasm] " + lines);
      buffered = buffered.slice(newline + 1);
    }
    lineBuffers.set(fd, buffered);
  };
  const builtins = {
    args_sizes_get: (argc, argvBufSize) => {
      view().setUint32(argc, 0, true);
      view().setUint32(argvBufSize, 0, true);
      return WASI_SUCCESS;
    },
    args_get: () => WASI_SUCCESS,
    environ_sizes_get: (count, bufSize) => {
      view().setUint32(count, 0, true);
      view().setUint32(bufSize, 0, true);
      return WASI_SUCCESS;
    },
    environ_get: () => WASI_SUCCESS,
    fd_fdstat_get: (_fd, stat) => {
      for (let i = 0; i < 24; i++) view().setUint8(stat + i, 0);
      return WASI_SUCCESS;
    },
    fd_prestat_get: () => WASI_EBADF,
    fd_prestat_dir_name: () => WASI_EBADF,
    fd_close: () => WASI_SUCCESS,
    fd_read: (_fd, _iovs, _n, nread) => {
      view().setUint32(nread, 0, true);
      return WASI_SUCCESS;
    },
    fd_seek: (_fd, _offset, _whence, newOffset) => {
      view().setUint32(newOffset, 0, true);
      return WASI_SUCCESS;
    },
    fd_write: (fd, iovs, n, nwritten) => {
      let written = 0;
      let text = "";
      for (let i = 0; i < n; i++) {
        const ptr = view().getUint32(iovs + i * 8, true);
        const len = view().getUint32(iovs + i * 8 + 4, true);
        written += len;
        if (fd === 1 || fd === 2) {
          text += textDecoder.decode(new Uint8Array(getMemory().buffer, ptr, len));
        }
      }
      if (text) emit(fd, text);
      view().setUint32(nwritten, written, true);
      return WASI_SUCCESS;
    },
    // Foundation treats a failing clock as fatal (__CFDateInitialize traps
    // during _initialize), so wall/monotonic clocks are real. `performance`
    // keeps monotonic-ish semantics; clock ids can be told apart when
    // something needs them.
    clock_res_get: (_id, out) => {
      view().setBigUint64(out, 1000000n, true); // 1ms
      return WASI_SUCCESS;
    },
    clock_time_get: (_id, _precision, out) => {
      const ms = performance.timeOrigin + performance.now();
      view().setBigUint64(out, BigInt(Math.round(ms * 1e6)), true);
      return WASI_SUCCESS;
    },
    path_open: () => WASI_EBADF,
    proc_exit: (code) => {
      throw new Error(`proc_exit(${code})`);
    },
    random_get: (ptr, len) => {
      // The ONLY randomness a wasip1 guest gets: Swift's
      // SystemRandomNumberGenerator and swift-crypto key generation bottom
      // out here, so it must be the platform CSPRNG. No fallback — a missing
      // crypto object should fail loudly, never degrade to Math.random().
      const bytes = new Uint8Array(getMemory().buffer, ptr, len);
      for (let off = 0; off < len; off += 65536) {
        // getRandomValues caps at 65536 bytes per call.
        crypto.getRandomValues(bytes.subarray(off, Math.min(off + 65536, len)));
      }
      return WASI_SUCCESS;
    },
  };
  const overrides = typeof overridesOrFactory === "function"
    ? overridesOrFactory(getMemory, builtins)
    : overridesOrFactory;
  const known = { ...builtins, ...overrides };
  return new Proxy(known, {
    get: (target, name) => target[name] ?? (() => WASI_ENOSYS),
  });
}

// --- The erased wire encoding ("blob", see bridge_ffi.h) --------------------

export const Tags = {
  void: 0,
  int: 1,
  int32: 2,
  double: 3,
  bool: 4,
  string: 5,
  bytes: 6,
  struct: 7,
  list: 8,
  handle: 9,
  error: 10,
  foreign: 11,
};

export class BlobWriter {
  chunks = [];

  i32(value) {
    const b = new DataView(new ArrayBuffer(4));
    b.setInt32(0, value, true);
    this.push(new Uint8Array(b.buffer));
    return this;
  }

  i64(value) {
    const b = new DataView(new ArrayBuffer(8));
    b.setBigInt64(0, value, true);
    this.push(new Uint8Array(b.buffer));
    return this;
  }

  f64(value) {
    const b = new DataView(new ArrayBuffer(8));
    b.setFloat64(0, value, true);
    this.push(new Uint8Array(b.buffer));
    return this;
  }

  bytes(value) {
    this.push(value);
    return this;
  }

  header(tag, aux) {
    return this.i32(tag).i32(aux);
  }

  /** A STRUCT/HANDLE/FOREIGN header: types are identified on the wire by
   * NAME (aux is the name's byte length, the name follows). */
  typeHeader(tag, name) {
    const bytes = encoder.encode(name);
    return this.i32(tag).i32(bytes.length).bytes(bytes);
  }

  push(bytes) {
    for (const byte of bytes) this.chunks.push(byte);
  }

  data() {
    return new Uint8Array(this.chunks);
  }
}

export class BlobReader {
  view;
  raw;
  cursor = 0;

  constructor(bytes) {
    this.raw = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  i32() {
    const v = this.view.getInt32(this.cursor, true);
    this.cursor += 4;
    return v;
  }

  i64() {
    const v = this.view.getBigInt64(this.cursor, true);
    this.cursor += 8;
    return v;
  }

  f64() {
    const v = this.view.getFloat64(this.cursor, true);
    this.cursor += 8;
    return v;
  }

  bytes(count) {
    const v = this.raw.slice(this.cursor, this.cursor + count);
    this.cursor += count;
    return v;
  }

  /** True when every byte has been consumed. */
  get done() {
    return this.cursor >= this.raw.byteLength;
  }
}

/** Reads a (tag, aux) header where aux is a type-name byte length, returning
 * the tag and the name (STRUCT/HANDLE/FOREIGN carry names; other tags have
 * aux 0 and an empty name). */
export function readTypeHeader(r) {
  const tag = r.i32();
  const aux = r.i32();
  const name = aux > 0 ? decoder.decode(r.bytes(aux)) : "";
  return { tag, name };
}

/** Reads a HANDLE value (a +1 or borrowed Swift box, per direction),
 * returning its bits. */
export function readHandleBits(r, expected) {
  const { tag, name } = readTypeHeader(r);
  if (tag !== Tags.handle) throw new SwiftError(`expected ${expected} handle, got tag ${tag}`);
  if (name && name !== expected) throw new SwiftError(`expected ${expected}, got ${name}`);
  return Number(r.i64());
}

/** Writes a HANDLE value (an interface instance by Swift box handle). */
export function writeHandle(w, name, bits) {
  w.typeHeader(Tags.handle, name);
  w.i64(BigInt(bits));
}

/** Writes a FOREIGN value (a consumer implementation by foreign-registry id). */
export function writeForeign(w, name, id) {
  w.typeHeader(Tags.foreign, name);
  w.i64(BigInt(id));
}

// A runtime type token (BridgeType in the .d.ts): JavaScript has no
// generics to carry a type, so generic bridge calls take one of these per
// type parameter (e.g. `Types.int`, `Types.result(Types.string)`, or a
// generated `<Struct>Type`).
function scalar(tag, write, read, name) {
  return {
    encode(w, v) {
      w.header(tag, 0);
      write(w, v);
    },
    decode(r) {
      const t = r.i32();
      r.i32();
      if (t !== tag) throw new SwiftError(`expected ${name}, got tag ${t}`);
      return read(r);
    },
  };
}

export const Types = {
  /** Swift `Int` (a 64-bit value; safe up to 2^53). */
  int: scalar(Tags.int, (w, v) => w.i64(BigInt(v)), (r) => Number(r.i64()), "Int"),
  int32: scalar(Tags.int32, (w, v) => w.i64(BigInt(v)), (r) => Number(r.i64()), "Int32"),
  double: scalar(Tags.double, (w, v) => w.f64(v), (r) => r.f64(), "Double"),
  bool: scalar(Tags.bool, (w, v) => w.i64(v ? 1n : 0n), (r) => r.i64() !== 0n, "Bool"),
  string: scalar(
    Tags.string,
    (w, v) => {
      const bytes = encoder.encode(v);
      w.i64(BigInt(bytes.length)).bytes(bytes);
    },
    (r) => decoder.decode(r.bytes(Number(r.i64()))),
    "String",
  ),
  bytes: scalar(
    Tags.bytes,
    (w, v) => w.i64(BigInt(v.length)).bytes(v),
    (r) => r.bytes(Number(r.i64())),
    "[UInt8]",
  ),
  /** Swift `Result<T, Error>` as a value: a LIST of [isError, payload] (the
   * general container encoding — see array/dictionary below). */
  result(inner) {
    return {
      encode(w, v) {
        w.header(Tags.list, 0);
        w.i64(2n);
        Types.bool.encode(w, !v.ok);
        if (v.ok) inner.encode(w, v.value);
        else Types.string.encode(w, v.error.message);
      },
      decode(r) {
        const count = readListHeader(r, "Result");
        if (count !== 2) throw new SwiftError(`expected Result, got list of ${count}`);
        if (Types.bool.decode(r)) return { ok: false, error: new SwiftError(Types.string.decode(r)) };
        return { ok: true, value: inner.decode(r) };
      },
    };
  },
  /** Swift `Array<Element>` as a value: a LIST of the elements. */
  array(element) {
    return {
      encode(w, v) {
        w.header(Tags.list, 0);
        w.i64(BigInt(v.length));
        for (const item of v) element.encode(w, item);
      },
      decode(r) {
        const count = readListHeader(r, "Array");
        const items = [];
        for (let i = 0; i < count; i++) items.push(element.decode(r));
        return items;
      },
    };
  },
  /** Swift `Dictionary<Key, Value>` as a value: a LIST of alternating
   * key/value pairs (unordered). */
  dictionary(key, value) {
    return {
      encode(w, v) {
        w.header(Tags.list, 0);
        w.i64(BigInt(v.size * 2));
        for (const [k, item] of v) {
          key.encode(w, k);
          value.encode(w, item);
        }
      },
      decode(r) {
        const count = readListHeader(r, "Dictionary");
        if (count % 2 !== 0) throw new SwiftError(`expected Dictionary, got list of ${count}`);
        const map = new Map();
        for (let i = 0; i < count; i += 2) map.set(key.decode(r), value.decode(r));
        return map;
      },
    };
  },
};

/** Reads a LIST header, returning the element count. */
function readListHeader(r, expected) {
  const tag = r.i32();
  r.i32();
  if (tag !== Tags.list) throw new SwiftError(`expected ${expected}, got tag ${tag}`);
  return Number(r.i64());
}

export function encodeWith(type, value) {
  const writer = new BlobWriter();
  type.encode(writer, value);
  return writer.data();
}

export function decodeWith(type, bytes) {
  return type.decode(new BlobReader(bytes));
}

/** If the blob is an ERROR blob, its message (the invoke/closure failure
 * channel); null otherwise. */
export function errorMessageOf(bytes) {
  if (bytes.byteLength < 4) return null;
  const r = new BlobReader(bytes);
  const tag = r.i32();
  if (tag !== Tags.error) return null;
  r.i32();
  return decoder.decode(r.bytes(Number(r.i64())));
}

/** Encodes an error message as an ERROR blob (closure failure channel). */
export function encodeErrorBlob(message) {
  const bytes = encoder.encode(message);
  return new BlobWriter().header(Tags.error, 0).i64(BigInt(bytes.length)).bytes(bytes).data();
}

/** A deferred Swift value: the Swift-side computation runs on first
 * `value()` (then caches, releasing the handle). */
export class Lazy {
  runtime;
  type;
  handle;
  cached;
  hasValue = false;

  /** @internal */
  constructor(runtime, handle, type) {
    this.runtime = runtime;
    this.type = type;
    this.handle = handle;
    registry.register(this, () => runtime.call("swift_ffi_lazy_release", handle), this);
  }

  value() {
    if (!this.hasValue) {
      if (this.handle === 0) throw new Error("Lazy used after close()");
      const box = this.runtime.call("swift_ffi_lazy_get", this.handle);
      this.cached = decodeWith(this.type, takeBytes(this.runtime, box));
      this.hasValue = true;
      this.close();
    }
    return this.cached;
  }

  /** Releases the underlying Swift handle. Idempotent. */
  close() {
    if (this.handle !== 0) {
      registry.unregister(this);
      this.runtime.call("swift_ffi_lazy_release", this.handle);
      this.handle = 0;
    }
  }
}
