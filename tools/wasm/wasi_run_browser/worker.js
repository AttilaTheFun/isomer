// wasi_run_browser's worker: a WASI command module (wasm32-unknown-wasip1)
// run to its end, as //tools/wasm/wasi_run runs one under WasmKit, but by the
// browser's own engine. run.json, beside this file, says what to run:
// { "module": <its file, also argv[0]>, "args": [...], "env": {...} }.
//
// The files are the web's (runtime/file_system.js, apps' own): HOME laid out
// as an iOS container, /tmp in memory, the whole tree preopened as fd 3.
// stdout and stderr go to the page as they are written, and the exit code
// once `_start` returns (0), the guest calls proc_exit, or it traps (1, as
// wasi_run). A worker, so a long `_start` holds no page up; a sleep
// (poll_oneoff on a clock) waits by the clock, since Atomics.wait needs a
// page served cross-origin isolated.

import { openAppFiles } from "./file_system.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const SUCCESS = 0;
const EBADF = 8;
const EINVAL = 28;
const ENOTSUP = 58;

class Exit {
  constructor(code) { this.code = code; }
}

const send = (fd, text) => postMessage({ kind: "output", fd, text });

async function main() {
  const run = await (await fetch("./run.json")).json();
  const files = await openAppFiles(`wasi_run_browser:${run.module}`);
  const bytes = await (await fetch(`./${run.module}`)).arrayBuffer();
  const module = await WebAssembly.compile(bytes);

  let memory = null;
  const view = () => new DataView(memory.buffer);
  const heap = () => new Uint8Array(memory.buffer);
  const argv = [run.module, ...run.args].map((argument) => encoder.encode(argument + "\0"));
  const now = (id) => id === 0
    ? BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6))
    : BigInt(Math.round(performance.now() * 1e6));

  // What file_system.js doesn't answer: the arguments, the standard
  // streams, clocks, randomness, sleeps and the exit.
  const builtins = {
    args_sizes_get(count, size) {
      view().setUint32(count, argv.length, true);
      view().setUint32(size, argv.reduce((total, argument) => total + argument.length, 0), true);
      return SUCCESS;
    },
    args_get(pointers, buffer) {
      for (const [i, argument] of argv.entries()) {
        view().setUint32(pointers + i * 4, buffer, true);
        heap().set(argument, buffer);
        buffer += argument.length;
      }
      return SUCCESS;
    },
    fd_write(fd, iovs, count, written) {
      if (fd !== 1 && fd !== 2) return EBADF;
      let total = 0;
      let text = "";
      for (let i = 0; i < count; i++) {
        const pointer = view().getUint32(iovs + i * 8, true);
        const length = view().getUint32(iovs + i * 8 + 4, true);
        text += decoder.decode(heap().slice(pointer, pointer + length), { stream: true });
        total += length;
      }
      if (text) send(fd, text);
      view().setUint32(written, total, true);
      return SUCCESS;
    },
    // No standard input: at its end at once.
    fd_read(fd, _iovs, _count, read) {
      if (fd !== 0) return EBADF;
      view().setUint32(read, 0, true);
      return SUCCESS;
    },
    fd_fdstat_get(fd, stat) {
      if (fd > 2) return EBADF;
      heap().fill(0, stat, stat + 24);
      view().setUint8(stat, 2); // a character device
      view().setBigUint64(stat + 8, 0xffffffffn, true);
      view().setBigUint64(stat + 16, 0xffffffffn, true);
      return SUCCESS;
    },
    fd_close: (fd) => (fd <= 2 ? SUCCESS : EBADF),
    fd_prestat_get: () => EBADF,
    clock_res_get(_id, resolution) {
      view().setBigUint64(resolution, 1000n, true);
      return SUCCESS;
    },
    clock_time_get(id, _precision, time) {
      if (id > 3) return EINVAL;
      view().setBigUint64(time, now(id), true);
      return SUCCESS;
    },
    random_get(pointer, length) {
      for (let offset = 0; offset < length; offset += 65536) {
        crypto.getRandomValues(heap().subarray(pointer + offset, pointer + Math.min(length, offset + 65536)));
      }
      return SUCCESS;
    },
    // Clocks wait until the earliest of them is due; a stream is ready at
    // once (writes never block; standard input is at its end).
    poll_oneoff(subscriptions, events, count, ready) {
      if (count === 0) return EINVAL;
      const v = view();
      let deadline = null;
      for (let i = 0; i < count; i++) {
        const at = subscriptions + i * 48;
        if (v.getUint8(at + 8) !== 0) { deadline = 0n; continue; }
        const id = v.getUint32(at + 16, true);
        const timeout = v.getBigUint64(at + 24, true);
        const absolute = (v.getUint16(at + 40, true) & 1) !== 0;
        const due = absolute ? timeout : now(id) + timeout;
        const wait = due - now(id);
        if (deadline === null || wait < deadline) deadline = wait;
      }
      const until = performance.now() + Math.max(0, Number(deadline)) / 1e6;
      while (performance.now() < until) { /* waiting */ }
      let written = 0;
      for (let i = 0; i < count; i++) {
        const at = subscriptions + i * 48;
        const type = view().getUint8(at + 8);
        if (type === 0) {
          const id = view().getUint32(at + 16, true);
          const timeout = view().getBigUint64(at + 24, true);
          const absolute = (view().getUint16(at + 40, true) & 1) !== 0;
          if (absolute && now(id) < timeout) continue;
        }
        const event = events + written * 32;
        heap().fill(0, event, event + 32);
        view().setBigUint64(event, view().getBigUint64(at, true), true);
        view().setUint8(event + 10, type);
        written++;
      }
      view().setUint32(ready, written, true);
      return SUCCESS;
    },
    sched_yield: () => SUCCESS,
    proc_exit(code) {
      throw new Exit(code);
    },
    proc_raise: () => ENOTSUP,
  };

  const wasi = files.wasi(() => memory, builtins, { environment: run.env });
  // Any WASI call nobody answers: not supported, rather than a link error.
  const imports = { wasi_snapshot_preview1: {} };
  for (const { module: from, name, kind } of WebAssembly.Module.imports(module)) {
    if (kind !== "function") continue;
    if (from !== "wasi_snapshot_preview1") {
      throw new Error(`the module imports ${from}.${name}, which a WASI command runner doesn't give`);
    }
    imports[from][name] = wasi[name] || builtins[name] || (() => ENOTSUP);
  }
  const instance = await WebAssembly.instantiate(module, imports);
  memory = instance.exports.memory;
  try {
    instance.exports._start();
    return 0;
  } catch (error) {
    if (error instanceof Exit) return error.code;
    send(2, `wasi_run_browser: the module trapped: ${error && error.stack ? error.stack : error}\n`);
    return 1;
  }
}

main().then(
  (code) => postMessage({ kind: "exit", code }),
  (error) => {
    send(2, `wasi_run_browser: ${error && error.message ? error.message : error}\n`);
    postMessage({ kind: "exit", code: 1 });
  },
);
