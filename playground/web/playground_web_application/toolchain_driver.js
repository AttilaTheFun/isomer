// The in-browser compile driver: runs `swift-frontend.wasm` and
// `wasm-ld.wasm` (tools/browser_toolchain) inside a Web Worker over a
// synchronous WASI preview1 shim and an in-memory filesystem, playing the
// part of the `swiftc` driver (which forks subprocesses — wasm cannot).
//
//   compileWithToolchain(toolchain, source) → { ok, wasm } | { ok, diagnostics }
//
// `toolchain.manifest` (toolchain/manifest.json) describes the bundle:
//   { "frontend": "swift-frontend.wasm", "linker": "wasm-ld.wasm",
//     "sdk": { "resourceDir": "resource-dir", "sysroot": "sysroot",
//              "modules": "sdk/modules", "archives": ["sdk/lib/libSwiftUI.a", …],
//              "clangModules": [{ "modulemap": "…", "include": "…" }] },
//     "files": [ { "path": "resource-dir/…", "size": N }, … ] }
// and `toolchain.files` maps every bundle path to its bytes.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// --- In-memory filesystem ---------------------------------------------------
// Paths are absolute inside the guest ("/toolchain/…", "/work/…"); the WASI
// preopens are the roots. Directories are implicit (any prefix of a file).

export class MemFS {
  constructor() { this.files = new Map(); }
  put(path, bytes) { this.files.set(normalize(path), bytes); }
  get(path) { return this.files.get(normalize(path)); }
  has(path) { return this.files.has(normalize(path)); }
  delete(path) { return this.files.delete(normalize(path)); }
  isDir(path) {
    const p = normalize(path);
    if (p === "/") return true;
    const prefix = p.endsWith("/") ? p : p + "/";
    for (const key of this.files.keys()) if (key.startsWith(prefix)) return true;
    return false;
  }
  list(path) {
    const p = normalize(path);
    const prefix = p === "/" ? "/" : p + "/";
    const names = new Set();
    for (const key of this.files.keys()) {
      if (!key.startsWith(prefix)) continue;
      const rest = key.slice(prefix.length);
      const slash = rest.indexOf("/");
      names.add(slash === -1 ? { name: rest, dir: false } : { name: rest.slice(0, slash), dir: true });
    }
    const out = new Map();
    for (const entry of names) if (!out.has(entry.name) || entry.dir) out.set(entry.name, entry.dir);
    return [...out.entries()].map(([name, dir]) => ({ name, dir }));
  }
}

export function normalize(path) {
  const parts = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") { parts.pop(); continue; }
    parts.push(part);
  }
  return "/" + parts.join("/");
}

// --- WASI preview1 ----------------------------------------------------------

const ERRNO = { SUCCESS: 0, E2BIG: 1, ACCES: 2, BADF: 8, EXIST: 20, INVAL: 28, IO: 29, ISDIR: 31, NOENT: 44, NOSYS: 52, NOTDIR: 54, NOTEMPTY: 55, NOTSUP: 58, SPIPE: 70 };
const FILETYPE = { UNKNOWN: 0, DIRECTORY: 3, REGULAR_FILE: 4, CHARACTER_DEVICE: 2 };
const OFLAGS = { CREAT: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 };
const RIGHTS_FD_READ = 1n << 1n, RIGHTS_FD_WRITE = 1n << 6n;

class ProcExit extends Error {
  constructor(code) { super("proc_exit " + code); this.code = code; }
}

/** A WASI instance over `fs` with `preopens` (guest dir → mounted). stdout/
 *  stderr lines go to `onOutput(fd, text)`. */
export class WASI {
  constructor({ fs, args = [], env = {}, preopens = ["/toolchain", "/work"], onOutput = () => {} }) {
    this.fs = fs;
    this.args = args;
    this.env = Object.entries(env).map(([k, v]) => `${k}=${v}`);
    this.onOutput = onOutput;
    this.memory = null;
    this.fds = new Map();
    // 0,1,2: std streams; then one preopen per directory.
    this.fds.set(0, { kind: "stream", fd: 0 });
    this.fds.set(1, { kind: "stream", fd: 1, buffer: "" });
    this.fds.set(2, { kind: "stream", fd: 2, buffer: "" });
    let next = 3;
    for (const dir of preopens) this.fds.set(next++, { kind: "dir", path: normalize(dir), preopen: true });
    this.nextFD = next;
  }

  get imports() {
    const w = this;
    // ISO_WASI_TRACE=1 (Node) logs file opens/reads for debugging the FS.
    const trace = typeof process !== "undefined" && process.env && process.env.ISO_WASI_TRACE ? (...a) => console.error("[wasi]", ...a) : null;
    const view = () => new DataView(w.memory.buffer);
    const bytes = () => new Uint8Array(w.memory.buffer);
    const readString = (ptr, len) => decoder.decode(bytes().subarray(ptr, ptr + len));
    const writeU32 = (ptr, value) => view().setUint32(ptr, value >>> 0, true);
    const writeU64 = (ptr, value) => view().setBigUint64(ptr, BigInt(value), true);
    const resolve = (dirFD, ptr, len) => {
      const entry = w.fds.get(dirFD);
      if (!entry || entry.kind !== "dir") return null;
      const rel = readString(ptr, len);
      return normalize(rel.startsWith("/") ? rel : entry.path + "/" + rel);
    };
    const filestat = (ptr, path, isDir, size) => {
      const v = view();
      v.setBigUint64(ptr, 0n, true);                 // dev
      v.setBigUint64(ptr + 8, BigInt(hash(path)), true); // ino
      v.setUint8(ptr + 16, isDir ? FILETYPE.DIRECTORY : FILETYPE.REGULAR_FILE);
      v.setBigUint64(ptr + 24, 1n, true);            // nlink
      v.setBigUint64(ptr + 32, BigInt(size), true);  // size
      v.setBigUint64(ptr + 40, 0n, true); v.setBigUint64(ptr + 48, 0n, true); v.setBigUint64(ptr + 56, 0n, true);
    };
    const iovs = (ptr, count) => {
      const v = view(); const out = [];
      for (let i = 0; i < count; i++) out.push({ ptr: v.getUint32(ptr + i * 8, true), len: v.getUint32(ptr + i * 8 + 4, true) });
      return out;
    };
    return {
      args_sizes_get(countPtr, sizePtr) {
        writeU32(countPtr, w.args.length);
        writeU32(sizePtr, w.args.reduce((n, a) => n + encoder.encode(a).length + 1, 0));
        return ERRNO.SUCCESS;
      },
      args_get(argvPtr, bufPtr) {
        let offset = bufPtr;
        w.args.forEach((arg, i) => {
          writeU32(argvPtr + i * 4, offset);
          const b = encoder.encode(arg);
          bytes().set(b, offset); bytes()[offset + b.length] = 0; offset += b.length + 1;
        });
        return ERRNO.SUCCESS;
      },
      environ_sizes_get(countPtr, sizePtr) {
        writeU32(countPtr, w.env.length);
        writeU32(sizePtr, w.env.reduce((n, a) => n + encoder.encode(a).length + 1, 0));
        return ERRNO.SUCCESS;
      },
      environ_get(envPtr, bufPtr) {
        let offset = bufPtr;
        w.env.forEach((entry, i) => {
          writeU32(envPtr + i * 4, offset);
          const b = encoder.encode(entry);
          bytes().set(b, offset); bytes()[offset + b.length] = 0; offset += b.length + 1;
        });
        return ERRNO.SUCCESS;
      },
      clock_res_get(id, ptr) { writeU64(ptr, 1000n); return ERRNO.SUCCESS; },
      clock_time_get(id, precision, ptr) {
        const now = id === 0 ? Date.now() * 1e6 : Math.round(performance.now() * 1e6);
        writeU64(ptr, BigInt(Math.round(now)));
        return ERRNO.SUCCESS;
      },
      random_get(ptr, len) { crypto.getRandomValues(bytes().subarray(ptr, ptr + len)); return ERRNO.SUCCESS; },
      sched_yield() { return ERRNO.SUCCESS; },
      proc_exit(code) { throw new ProcExit(code); },
      proc_raise() { return ERRNO.NOSYS; },
      fd_prestat_get(fd, ptr) {
        const entry = w.fds.get(fd);
        if (!entry || !entry.preopen) return ERRNO.BADF;
        const v = view(); v.setUint8(ptr, 0); v.setUint32(ptr + 4, encoder.encode(entry.path).length, true);
        return ERRNO.SUCCESS;
      },
      fd_prestat_dir_name(fd, ptr, len) {
        const entry = w.fds.get(fd);
        if (!entry || !entry.preopen) return ERRNO.BADF;
        bytes().set(encoder.encode(entry.path).subarray(0, len), ptr);
        return ERRNO.SUCCESS;
      },
      fd_fdstat_get(fd, ptr) {
        const entry = w.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        const v = view();
        v.setUint8(ptr, entry.kind === "dir" ? FILETYPE.DIRECTORY : entry.kind === "stream" ? FILETYPE.CHARACTER_DEVICE : FILETYPE.REGULAR_FILE);
        v.setUint16(ptr + 2, 0, true);
        v.setBigUint64(ptr + 8, ~0n & ((1n << 64n) - 1n), true);
        v.setBigUint64(ptr + 16, ~0n & ((1n << 64n) - 1n), true);
        return ERRNO.SUCCESS;
      },
      fd_fdstat_set_flags() { return ERRNO.SUCCESS; },
      fd_fdstat_set_rights() { return ERRNO.SUCCESS; },
      fd_filestat_get(fd, ptr) {
        const entry = w.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        if (entry.kind === "dir") { filestat(ptr, entry.path, true, 0); return ERRNO.SUCCESS; }
        if (entry.kind === "stream") { filestat(ptr, "/dev/std" + fd, false, 0); return ERRNO.SUCCESS; }
        filestat(ptr, entry.path, false, entry.data.length);
        return ERRNO.SUCCESS;
      },
      fd_filestat_set_size(fd, size) {
        const entry = w.fds.get(fd);
        if (!entry || entry.kind !== "file") return ERRNO.BADF;
        const n = Number(size);
        const next = new Uint8Array(n); next.set(entry.data.subarray(0, Math.min(n, entry.data.length)));
        entry.data = next; w.fs.put(entry.path, entry.data);
        return ERRNO.SUCCESS;
      },
      fd_filestat_set_times() { return ERRNO.SUCCESS; },
      path_filestat_get(dirFD, flags, ptr, len, statPtr) {
        const path = resolve(dirFD, ptr, len);
        if (path === null) return ERRNO.BADF;
        if (w.fs.has(path)) { filestat(statPtr, path, false, w.fs.get(path).length); return ERRNO.SUCCESS; }
        if (w.fs.isDir(path) || w.preopenPath(path)) { filestat(statPtr, path, true, 0); return ERRNO.SUCCESS; }
        return ERRNO.NOENT;
      },
      path_filestat_set_times() { return ERRNO.SUCCESS; },
      path_open(dirFD, dirflags, ptr, len, oflags, rightsBase, rightsInheriting, fdflags, fdPtr) {
        const path = resolve(dirFD, ptr, len);
        if (path === null) return ERRNO.BADF;
        const wantsDir = (oflags & OFLAGS.DIRECTORY) !== 0;
        if (w.fs.isDir(path) || w.preopenPath(path)) {
          if (!w.fs.has(path)) {
            const fd = w.nextFD++;
            w.fds.set(fd, { kind: "dir", path });
            writeU32(fdPtr, fd);
            return ERRNO.SUCCESS;
          }
        }
        if (wantsDir) return w.fs.has(path) ? ERRNO.NOTDIR : ERRNO.NOENT;
        let data = w.fs.get(path);
        if (data === undefined) {
          if (!(oflags & OFLAGS.CREAT)) return ERRNO.NOENT;
          data = new Uint8Array(0); w.fs.put(path, data);
        } else if (oflags & OFLAGS.EXCL) {
          return ERRNO.EXIST;
        }
        if (oflags & OFLAGS.TRUNC) { data = new Uint8Array(0); w.fs.put(path, data); }
        const fd = w.nextFD++;
        const append = (fdflags & 1) !== 0;
        w.fds.set(fd, { kind: "file", path, data, position: append ? data.length : 0, append });
        if (trace) trace("open", fd, path, data.length, "oflags", oflags, "fdflags", fdflags);
        writeU32(fdPtr, fd);
        return ERRNO.SUCCESS;
      },
      fd_close(fd) { if (!w.fds.has(fd)) return ERRNO.BADF; w.fds.delete(fd); return ERRNO.SUCCESS; },
      fd_sync() { return ERRNO.SUCCESS; },
      fd_datasync() { return ERRNO.SUCCESS; },
      fd_seek(fd, offset, whence, ptr) {
        const entry = w.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        if (entry.kind !== "file") return ERRNO.SPIPE;
        const delta = Number(offset);
        let position = whence === 0 ? delta : whence === 1 ? entry.position + delta : entry.data.length + delta;
        if (position < 0) return ERRNO.INVAL;
        entry.position = position;
        if (trace) trace("seek", fd, entry.path, "->", position, "whence", whence);
        writeU64(ptr, BigInt(position));
        return ERRNO.SUCCESS;
      },
      fd_tell(fd, ptr) {
        const entry = w.fds.get(fd);
        if (!entry || entry.kind !== "file") return ERRNO.BADF;
        writeU64(ptr, BigInt(entry.position));
        return ERRNO.SUCCESS;
      },
      fd_read(fd, iovPtr, iovCount, nreadPtr) {
        const entry = w.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        if (entry.kind !== "file") { writeU32(nreadPtr, 0); return ERRNO.SUCCESS; }
        let total = 0;
        for (const { ptr, len } of iovs(iovPtr, iovCount)) {
          const chunk = entry.data.subarray(entry.position, entry.position + len);
          bytes().set(chunk, ptr);
          entry.position += chunk.length; total += chunk.length;
          if (chunk.length < len) break;
        }
        if (trace) trace("read", fd, entry.path, "at", entry.position - total, "n", total);
        writeU32(nreadPtr, total);
        return ERRNO.SUCCESS;
      },
      fd_pread(fd, iovPtr, iovCount, offset, nreadPtr) {
        const entry = w.fds.get(fd);
        if (!entry || entry.kind !== "file") return ERRNO.BADF;
        let position = Number(offset), total = 0;
        for (const { ptr, len } of iovs(iovPtr, iovCount)) {
          const chunk = entry.data.subarray(position, position + len);
          bytes().set(chunk, ptr); position += chunk.length; total += chunk.length;
          if (chunk.length < len) break;
        }
        if (trace) trace("pread", fd, entry.path, "at", Number(offset), "n", total);
        writeU32(nreadPtr, total);
        return ERRNO.SUCCESS;
      },
      fd_write(fd, iovPtr, iovCount, nwrittenPtr) {
        const entry = w.fds.get(fd);
        if (!entry) return ERRNO.BADF;
        let total = 0;
        if (entry.kind === "stream") {
          for (const { ptr, len } of iovs(iovPtr, iovCount)) { entry.buffer += readString(ptr, len); total += len; }
          const lines = entry.buffer.split("\n"); entry.buffer = lines.pop();
          for (const line of lines) w.onOutput(fd, line);
          writeU32(nwrittenPtr, total);
          return ERRNO.SUCCESS;
        }
        if (entry.kind !== "file") return ERRNO.BADF;
        for (const { ptr, len } of iovs(iovPtr, iovCount)) {
          const chunk = bytes().subarray(ptr, ptr + len);
          const end = entry.position + len;
          if (end > entry.data.length) {
            const grown = new Uint8Array(Math.max(end, entry.data.length * 2));
            grown.set(entry.data); entry.data = grown.subarray(0, end); entry.full = grown;
          }
          entry.data.set(chunk, entry.position);
          entry.position = end; total += len;
        }
        w.fs.put(entry.path, entry.data);
        writeU32(nwrittenPtr, total);
        return ERRNO.SUCCESS;
      },
      fd_pwrite(fd, iovPtr, iovCount, offset, nwrittenPtr) {
        const entry = w.fds.get(fd);
        if (!entry || entry.kind !== "file") return ERRNO.BADF;
        const saved = entry.position; entry.position = Number(offset);
        const result = w.imports.fd_write(fd, iovPtr, iovCount, nwrittenPtr);
        entry.position = saved;
        return result;
      },
      fd_readdir(fd, bufPtr, bufLen, cookie, usedPtr) {
        const entry = w.fds.get(fd);
        if (!entry || entry.kind !== "dir") return ERRNO.BADF;
        const entries = [{ name: ".", dir: true }, { name: "..", dir: true }, ...w.fs.list(entry.path)];
        let offset = 0; const v = view(); const b = bytes();
        for (let i = Number(cookie); i < entries.length; i++) {
          // A dirent: d_next, d_ino, d_namlen, d_type, then the name.
          const name = encoder.encode(entries[i].name);
          const dirent = new Uint8Array(24 + name.length);
          const d = new DataView(dirent.buffer);
          d.setBigUint64(0, BigInt(i + 1), true);
          d.setBigUint64(8, BigInt(hash(entry.path + "/" + entries[i].name)), true);
          d.setUint32(16, name.length, true);
          d.setUint8(20, entries[i].dir ? FILETYPE.DIRECTORY : FILETYPE.REGULAR_FILE);
          dirent.set(name, 24);
          // One that does not fit goes in as far as it does (WASI's rule):
          // the reader sees its length, grows its buffer and asks again from
          // the entry before. Claiming the buffer full without it left the
          // reader parsing stale bytes as an entry, forever.
          const take = Math.min(dirent.length, bufLen - offset);
          b.set(dirent.subarray(0, take), bufPtr + offset);
          offset += take;
          if (take < dirent.length) break;
        }
        writeU32(usedPtr, offset);
        return ERRNO.SUCCESS;
      },
      path_create_directory(dirFD, ptr, len) { return resolve(dirFD, ptr, len) === null ? ERRNO.BADF : ERRNO.SUCCESS; },
      path_remove_directory() { return ERRNO.SUCCESS; },
      path_unlink_file(dirFD, ptr, len) {
        const path = resolve(dirFD, ptr, len);
        if (path === null) return ERRNO.BADF;
        return w.fs.delete(path) ? ERRNO.SUCCESS : ERRNO.NOENT;
      },
      path_rename(oldFD, oldPtr, oldLen, newFD, newPtr, newLen) {
        const from = resolve(oldFD, oldPtr, oldLen), to = resolve(newFD, newPtr, newLen);
        if (from === null || to === null) return ERRNO.BADF;
        const data = w.fs.get(from);
        if (data === undefined) return ERRNO.NOENT;
        w.fs.delete(from); w.fs.put(to, data);
        return ERRNO.SUCCESS;
      },
      // No symlinks here: an existing path is not one (readlink's EINVAL,
      // which realpath expects), a missing one is missing.
      path_readlink(dirFD, ptr, len) {
        const path = resolve(dirFD, ptr, len);
        if (path === null) return ERRNO.BADF;
        return w.fs.has(path) || w.fs.isDir(path) ? ERRNO.INVAL : ERRNO.NOENT;
      },
      path_symlink() { return ERRNO.NOSYS; },
      path_link() { return ERRNO.NOSYS; },
      fd_advise() { return ERRNO.SUCCESS; },
      fd_allocate() { return ERRNO.SUCCESS; },
      fd_renumber(from, to) { const e = w.fds.get(from); if (!e) return ERRNO.BADF; w.fds.set(to, e); w.fds.delete(from); return ERRNO.SUCCESS; },
      poll_oneoff() { return ERRNO.NOSYS; },
      sock_accept() { return ERRNO.NOSYS; }, sock_recv() { return ERRNO.NOSYS; }, sock_send() { return ERRNO.NOSYS; }, sock_shutdown() { return ERRNO.NOSYS; },
    };
  }

  preopenPath(path) { for (const e of this.fds.values()) if (e.kind === "dir" && e.preopen && (e.path === path || e.path.startsWith(path + "/"))) return true; return false; }

  /** Instantiates `module` and runs `_start`; returns the exit code.
   *  `extra` adds import modules (the compiler's `iso_plugin`). */
  run(module, extra = {}) {
    const instance = new WebAssembly.Instance(module, { ...extra, wasi_snapshot_preview1: this.imports });
    this.memory = instance.exports.memory;
    try {
      instance.exports._start();
      return 0;
    } catch (error) {
      if (error instanceof ProcExit) return error.code;
      throw error;
    } finally {
      for (const fd of [1, 2]) { const s = this.fds.get(fd); if (s && s.buffer) { this.onOutput(fd, s.buffer); s.buffer = ""; } }
    }
  }
}

// --- Macro plugins -----------------------------------------------------------
// The compiler runs no processes, so `-load-plugin-executable <path>#<modules>`
// names a wasm module in the bundle: a macro plugin built for wasm32-wasip1
// (build_macro_plugins.sh), whose `main` registers swift-syntax's handler and
// whose `swift_wasm_macro_v1_pump` answers one request from its stdin on its
// stdout. The compiler (swift-wasi-plugins.patch) reaches it through these
// `iso_plugin` imports: `write` gives it the compiler's framed request (an
// 8-byte little-endian length, then JSON), the plugin is pumped once a whole
// request is in, and `read` hands its framed answer back.

const pluginModules = new Map(); // bundle path -> WebAssembly.Module, kept by the worker

class PluginExit { constructor(code) { this.code = code; } }

/** One plugin instance: its stdin (the request being answered) and stdout. */
function startPlugin(bytes, path, log) {
  let module = pluginModules.get(path);
  if (!module) { module = new WebAssembly.Module(bytes); pluginModules.set(path, module); }
  let memory = null, stdin = new Uint8Array(0), stdinAt = 0;
  const stdout = [];
  const view = () => new DataView(memory.buffer);
  const iovecs = (iov, count, each) => {
    let total = 0;
    for (let i = 0; i < count; i++) {
      const done = each(view().getUint32(iov + i * 8, true), view().getUint32(iov + i * 8 + 4, true));
      total += done;
      if (done < view().getUint32(iov + i * 8 + 4, true)) break;
    }
    return total;
  };
  const wasi = {
    args_sizes_get(count, size) { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return 0; },
    args_get() { return 0; },
    environ_sizes_get(count, size) { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return 0; },
    environ_get() { return 0; },
    clock_time_get(id, precision, out) { view().setBigUint64(out, BigInt(Math.round(performance.now() * 1e6)), true); return 0; },
    clock_res_get(id, out) { view().setBigUint64(out, 1000n, true); return 0; },
    fd_close() { return 0; },
    fd_fdstat_get(fd, out) {
      new Uint8Array(memory.buffer, out, 24).fill(0);
      view().setUint8(out, 2); // a character device: the plugin's stdio
      return fd <= 2 ? 0 : 8;
    },
    fd_filestat_get() { return 8; },
    fd_prestat_get() { return 8; },
    fd_prestat_dir_name() { return 8; },
    fd_seek() { return 70; },
    path_open() { return 76; },
    poll_oneoff() { return 52; },
    sched_yield() { return 0; },
    random_get(ptr, length) { crypto.getRandomValues(new Uint8Array(memory.buffer, ptr, length)); return 0; },
    proc_exit(code) { throw new PluginExit(code); },
    fd_read(fd, iov, count, nread) {
      if (fd !== 0) return 8;
      view().setUint32(nread, iovecs(iov, count, (ptr, length) => {
        const take = Math.min(length, stdin.length - stdinAt);
        new Uint8Array(memory.buffer, ptr, take).set(stdin.subarray(stdinAt, stdinAt + take));
        stdinAt += take;
        return take;
      }), true);
      return 0;
    },
    fd_write(fd, iov, count, nwritten) {
      view().setUint32(nwritten, iovecs(iov, count, (ptr, length) => {
        const chunk = new Uint8Array(memory.buffer, ptr, length).slice();
        if (fd === 1) stdout.push(chunk); else log(decoder.decode(chunk));
        return length;
      }), true);
      return 0;
    },
  };
  // Anything else a plugin imports answers "not supported".
  const imports = new Proxy(wasi, { get: (target, name) => target[name] || (() => 52) });
  const instance = new WebAssembly.Instance(module, { wasi_snapshot_preview1: imports });
  memory = instance.exports.memory;
  try { instance.exports._start(); } catch (error) { if (!(error instanceof PluginExit)) throw error; }
  return {
    /** Answers one framed request; returns the framed answer. */
    answer(request) {
      stdin = request; stdinAt = 0; stdout.length = 0;
      instance.exports.swift_wasm_macro_v1_pump();
      const out = new Uint8Array(stdout.reduce((n, c) => n + c.length, 0));
      let at = 0;
      for (const chunk of stdout) { out.set(chunk, at); at += chunk.length; }
      return out;
    },
  };
}

/** The `iso_plugin` imports for one compile: plugins read from `fs`. */
function pluginImports(fs, compilerMemory, log) {
  const trace = typeof process !== "undefined" && process.env && process.env.ISO_PLUGIN_TRACE ? (...a) => console.error("[plugin]", ...a) : () => {};
  const plugins = new Map(); // handle -> { plugin, pending, answers, dead }
  let next = 1;
  const bytesAt = (ptr, length) => new Uint8Array(compilerMemory().buffer, ptr, length);
  const concat = (a, b) => { const out = new Uint8Array(a.length + b.length); out.set(a, 0); out.set(b, a.length); return out; };
  return {
    open(ptr, length) {
      const path = decoder.decode(bytesAt(ptr, length).slice());
      trace("open", path);
      const bytes = fs.get(path);
      if (!bytes) { log(`plugin not found: ${path}`); return -1; }
      try {
        const handle = next++;
        plugins.set(handle, { plugin: startPlugin(bytes, path, log), pending: new Uint8Array(0), answers: new Uint8Array(0), dead: false });
        return handle;
      } catch (error) { log(`plugin ${path} did not start: ${error}`); return -1; }
    },
    write(handle, ptr, length) {
      const entry = plugins.get(handle);
      trace("write", handle, length);
      if (!entry || entry.dead) return -1;
      entry.pending = concat(entry.pending, bytesAt(ptr, length).slice());
      while (entry.pending.length >= 8) {
        const size = Number(new DataView(entry.pending.buffer, entry.pending.byteOffset).getBigUint64(0, true));
        if (entry.pending.length < 8 + size) break;
        const request = entry.pending.slice(0, 8 + size);
        entry.pending = entry.pending.slice(8 + size);
        if (size === 0) { entry.dead = true; break; } // the compiler's goodbye
        try { entry.answers = concat(entry.answers, entry.plugin.answer(request)); }
        catch (error) { log(`plugin failed: ${error}`); entry.dead = true; return -1; }
      }
      return length;
    },
    read(handle, ptr, length) {
      const entry = plugins.get(handle);
      trace("read", handle, length, entry && entry.answers.length);
      if (!entry) return -1;
      const take = Math.min(length, entry.answers.length);
      bytesAt(ptr, take).set(entry.answers.subarray(0, take));
      entry.answers = entry.answers.slice(take);
      return take;
    },
    close(handle) { plugins.delete(handle); },
  };
}

function hash(text) { let h = 2166136261; for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; } return h; }

// --- Driving the compiler ----------------------------------------------------

let compiledModules = null;

/** A bundle entry is a file name, or an array of part names that concatenate
 *  (the compiler is far bigger than a static host's per-file limit). Parts
 *  live in `toolchain.files` (fetched by the worker, gunzipped if `.gz`). */
export function assemble(toolchain, entry) {
  const names = Array.isArray(entry) ? entry : [entry];
  if (names.length === 1) return toolchain.files.get(names[0]);
  const parts = names.map((n) => toolchain.files.get(n));
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) { out.set(part, offset); offset += part.length; }
  return out;
}

/** The compiled frontend / linker: streamed by the worker when it loaded
 *  the bundle (`toolchain.modules`), else compiled lazily from the bytes. */
async function moduleFor(toolchain, which) {
  if (toolchain.modules && toolchain.modules[which]) return toolchain.modules[which];
  compiledModules = compiledModules || {};
  if (!compiledModules[which]) compiledModules[which] = await WebAssembly.compile(assemble(toolchain, toolchain.manifest[which]));
  return compiledModules[which];
}

/** Hydrates the bundle into a fresh MemFS under /toolchain. */
function mount(toolchain) {
  const fs = new MemFS();
  for (const [path, bytes] of toolchain.files) fs.put("/toolchain/" + path, bytes);
  return fs;
}

export async function compileWithToolchain(toolchain, source) {
  const { manifest } = toolchain;
  const sdk = manifest.sdk;
  const frontend = await moduleFor(toolchain, "frontend");
  const linker = await moduleFor(toolchain, "linker");
  const fs = mount(toolchain);
  fs.put("/work/App.swift", encoder.encode(source));
  const output = [];
  const onOutput = (fd, line) => output.push(line);
  const T = (p) => "/toolchain/" + p;

  // 1. swift-frontend -frontend -c … (the flags `swiftc -driver-print-jobs`
  //    prints for the Playground's compile; the driver is bypassed).
  const frontendArgs = ["swift-frontend", "-frontend", "-c", "-primary-file", "/work/App.swift",
    "-target", "wasm32-unknown-wasip1", "-Xcc", "--target=wasm32-unknown-wasip1",
    "-disable-objc-interop", "-use-static-resource-dir", "-sdk", T(sdk.sysroot), "-resource-dir", T(sdk.resourceDir),
    "-I", T(sdk.modules), "-module-cache-path", "/work/module-cache",
    "-swift-version", "5", "-Onone", "-parse-as-library", "-module-name", "UserApp", "-o", "/work/UserApp.o"];
  for (const entry of sdk.clangModules || []) {
    if (entry.modulemap) frontendArgs.push("-Xcc", "-fmodule-map-file=" + T(entry.modulemap));
    if (entry.include) frontendArgs.push("-Xcc", "-I", "-Xcc", T(entry.include));
  }
  // Macros: each plugin the bundle carries, for the modules it serves.
  for (const plugin of manifest.plugins || []) {
    frontendArgs.push("-load-plugin-executable", T(plugin.path) + "#" + plugin.modules.join(","));
  }
  let wasi = new WASI({ fs, args: frontendArgs, env: { HOME: "/work", TMPDIR: "/work" }, onOutput });
  const plugins = pluginImports(fs, () => wasi.memory, (line) => onOutput(2, line));
  let code = wasi.run(frontend, { iso_plugin: plugins });
  if (code !== 0 || !fs.has("/work/UserApp.o")) {
    return { ok: false, diagnostics: output.join("\n").replaceAll("/work/", "") || `swift-frontend exited with ${code}` };
  }
  return linkWithToolchain(toolchain, fs.get("/work/UserApp.o"), { fs, linker });
}

/** The reactor link alone (also used to test the linker with a natively
 *  compiled object): `object` → { ok, wasm } | { ok, diagnostics }. */
export async function linkWithToolchain(toolchain, object, reuse = null) {
  const { manifest } = toolchain;
  const sdk = manifest.sdk;
  const linker = reuse ? reuse.linker : await moduleFor(toolchain, "linker");
  const fs = reuse ? reuse.fs : mount(toolchain);
  fs.put("/work/UserApp.o", object);
  const output = [];
  const onOutput = (fd, line) => output.push(line);
  const T = (p) => "/toolchain/" + p;

  // 2. wasm-ld: the reactor link (the flags the Playground's clang link expands to).
  const linkArgs = ["wasm-ld", "-m", "wasm32", "-L" + T(sdk.resourceDir) + "/wasi", "-L" + T(sdk.sysroot) + "/lib/wasm32-wasip1",
    T(sdk.sysroot) + "/lib/wasm32-wasip1/crt1-reactor.o", "--entry", "_initialize", "/work/UserApp.o", "--whole-archive"];
  for (const archive of sdk.archives) linkArgs.push(T(archive));
  linkArgs.push("--no-whole-archive");
  // The hosts' entries exported and the rest dead-stripped, as isomer ships
  // its reactors (Foundation would otherwise be all there); an SDK without
  // the list exports everything.
  if (sdk.exports) linkArgs.push("--gc-sections", ...sdk.exports.map((name) => "--export-if-defined=" + name));
  else linkArgs.push("--export-all", "--no-gc-sections");
  linkArgs.push("-z", "stack-size=16777216",
    T(sdk.resourceDir) + "/wasi/wasm32/swiftrt.o",
    "-lswiftCore", "-lswiftSwiftOnoneSupport", "-lswiftWASILibc", "-lswift_Concurrency", "-lswift_RegexParser", "-lswift_StringProcessing",
    "-lswiftObservation", "-lswiftSynchronization",
    "-lc++", "-lc++abi", "-ldl", "-lm", "-lwasi-emulated-mman", "-lwasi-emulated-signal", "-lwasi-emulated-process-clocks", "-lwasi-emulated-getpid",
    "--global-base=4096", "--table-base=4096", "-lc", T(sdk.resourceDir) + "/clang/lib/wasip1/libclang_rt.builtins-wasm32.a",
    "-o", "/work/UserApp.wasm");
  const wasi = new WASI({ fs, args: linkArgs, env: { HOME: "/work" }, onOutput });
  const code = wasi.run(linker);
  if (code !== 0 || !fs.has("/work/UserApp.wasm")) {
    return { ok: false, diagnostics: "link failed:\n" + (output.join("\n") || `wasm-ld exited with ${code}`) };
  }
  return { ok: true, wasm: fs.get("/work/UserApp.wasm").slice() };
}
