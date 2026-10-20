// The web's app files kept in IndexedDB in blocks (file_system.js): a write
// puts the blocks it touched, a shrink deletes what it gave up, a file kept
// whole before blocks still reads and moves into blocks, and a leaving
// page's journal (localStorage) holds the changed blocks the next load lays
// over what IndexedDB had. Node has no IndexedDB or localStorage: a small
// one of each, in memory, below. A fresh import of file_system.js is a page
// loaded again.

// --- An IndexedDB in memory: one database, one store, keys in IndexedDB's
// order. A transaction's changes apply together when it completes; while
// `frozen`, none complete (a page that went before its writes did).
const fake = { records: new Map(), frozen: false, puts: [] };
const typeRank = (k) => (typeof k === "number" ? 0 : typeof k === "string" ? 1 : 2);
function compare(a, b) {
  if (typeRank(a) !== typeRank(b)) return typeRank(a) - typeRank(b);
  if (!Array.isArray(a)) return a < b ? -1 : a > b ? 1 : 0;
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    const c = compare(a[i], b[i]);
    if (c) return c;
  }
  return a.length - b.length;
}
const keyText = (k) => JSON.stringify(k);
globalThis.IDBKeyRange = {
  bound: (lower, upper) => ({ lower, upper, includes: (k) => compare(lower, k) <= 0 && compare(k, upper) <= 0 }),
};
const request = (result) => {
  const r = { result };
  setTimeout(() => r.onsuccess && r.onsuccess());
  return r;
};
const sorted = (range) => [...fake.records.values()].filter(({ key }) => range.includes(key)).sort((a, b) => compare(a.key, b.key));
const store = (ops) => ({
  put: (value, key) => ops.push(() => {
    fake.records.set(keyText(key), { key, value: value instanceof Uint8Array ? value.slice() : structuredClone(value) });
    fake.puts.push(key);
  }),
  delete: (keyOrRange) => ops.push(() => {
    for (const [text, { key }] of fake.records) {
      if (keyOrRange.includes ? keyOrRange.includes(key) : compare(key, keyOrRange) === 0) fake.records.delete(text);
    }
  }),
  getAll: (range) => request(sorted(range).map(({ value }) => value)),
  getAllKeys: (range) => request(sorted(range).map(({ key }) => key)),
});
const database = {
  transaction: () => {
    const ops = [];
    const tx = { objectStore: () => store(ops), commit() {} };
    setTimeout(() => {
      if (fake.frozen) return;
      for (const op of ops) op();
      tx.oncomplete && tx.oncomplete();
    });
    return tx;
  },
};
globalThis.indexedDB = {
  open: () => {
    const r = { result: database };
    setTimeout(() => r.onsuccess());
    return r;
  },
};
const storage = new Map();
globalThis.localStorage = {
  getItem: (k) => (storage.has(k) ? storage.get(k) : null),
  setItem: (k, v) => storage.set(k, String(v)),
  removeItem: (k) => storage.delete(k),
};
// A page that can be left: each load's pagehide listener, called by leave().
let pagehide = null;
globalThis.window = { addEventListener: (type, listener) => { if (type === "pagehide") pagehide = listener; } };
globalThis.document = { addEventListener() {}, visibilityState: "visible" };

let failures = 0;
function check(name, found, expected) {
  const ok = JSON.stringify(found) === JSON.stringify(expected);
  if (!ok) failures += 1;
  console.log(ok ? `ok ${name}` : `FAIL ${name}: ${JSON.stringify(found)}, expected ${JSON.stringify(expected)}`);
}
const settle = () => new Promise((resolve) => setTimeout(resolve, 5));

// --- A page: its files, and the WASI calls on them, with a memory of its own.
const BLOCK = 1 << 16;
let loads = 0;
async function load(key) {
  const { openAppFiles } = await import(`./file_system.js?load=${++loads}`);
  const files = await openAppFiles(key);
  const memory = new WebAssembly.Memory({ initial: 16 });
  const wasi = files.wasi(() => memory);
  const bytes = () => new Uint8Array(memory.buffer);
  const view = () => new DataView(memory.buffer);
  const PATH = 64, RESULT = 512, IOVEC = 600, COUNT = 700, DATA = 4096;
  const encoder = new TextEncoder();
  const put = (text) => { const e = encoder.encode(text); bytes().set(e, PATH); return e.length; };
  const page = {
    files,
    open(path) {
      const error = wasi.path_open(3, 0, PATH, put(path), 1 /* O_CREAT */, (1n << 1n) | (1n << 6n), 0n, 0, RESULT);
      if (error) throw new Error(`open ${path}: ${error}`);
      return view().getUint32(RESULT, true);
    },
    // `data` at `offset`, through fd_pwrite.
    write(fd, offset, data) {
      bytes().set(data, DATA);
      view().setUint32(IOVEC, DATA, true);
      view().setUint32(IOVEC + 4, data.length, true);
      return wasi.fd_pwrite(fd, IOVEC, 1, BigInt(offset), COUNT);
    },
    truncate: (fd, size) => wasi.fd_filestat_set_size(fd, BigInt(size)),
    // The whole file, through fd_pread.
    read(path) {
      const fd = page.open(path);
      const out = [];
      for (let offset = 0; ; ) {
        view().setUint32(IOVEC, DATA, true);
        view().setUint32(IOVEC + 4, BLOCK, true);
        wasi.fd_pread(fd, IOVEC, 1, BigInt(offset), COUNT);
        const n = view().getUint32(COUNT, true);
        out.push(bytes().slice(DATA, DATA + n));
        offset += n;
        if (n < BLOCK) break;
      }
      wasi.fd_close(fd);
      const all = new Uint8Array(out.reduce((sum, part) => sum + part.length, 0));
      let at = 0;
      for (const part of out) { all.set(part, at); at += part.length; }
      return all;
    },
  };
  return page;
}
// Bytes that say where they are (so a block in the wrong place shows).
const pattern = (length, seed) => Uint8Array.from({ length }, (_, i) => (i * 31 + seed) & 0xff);
const same = (a, b) => a.length === b.length && a.every((value, i) => value === b[i]);
const putsSince = (from) => fake.puts.slice(from).map((key) => (key.length === 3 ? `block ${key[2]}` : "record"));
const blocksStored = (key, path) => sorted(IDBKeyRange.bound([key, path, 0], [key, path, Infinity])).map(({ key }) => key[2]);

const KEY = "blocks_test", DB = "home/app/Library/Application Support/cache.sqlite", REL = "Library/Application Support/cache.sqlite";

// A 300 KiB file: its record and five blocks.
let page = await load(KEY);
let fd = page.open(DB);
let expected = pattern(300 * 1024, 1);
page.write(fd, 0, expected);
let mark = fake.puts.length;
await page.files.flush();
await settle();
check("first write puts the record and every block", putsSince(mark).sort(), ["block 0", "block 1", "block 2", "block 3", "block 4", "record"]);

// A 4 KiB page rewritten at 130 KiB: its block and the record, no more.
const page4k = pattern(4096, 7);
page.write(fd, 130 * 1024, page4k);
expected.set(page4k, 130 * 1024);
mark = fake.puts.length;
await page.files.flush();
await settle();
check("a small write puts one block", putsSince(mark).sort(), ["block 2", "record"]);

// A write across a block boundary: both blocks.
const across = pattern(1000, 9);
page.write(fd, BLOCK - 500, across);
expected.set(across, BLOCK - 500);
mark = fake.puts.length;
await page.files.flush();
await settle();
check("a write across a boundary puts both blocks", putsSince(mark).sort(), ["block 0", "block 1", "record"]);

// Shrunk to 100 KiB: the cut block put again, the ones past it gone.
page.truncate(fd, 100 * 1024);
expected = expected.slice(0, 100 * 1024);
mark = fake.puts.length;
await page.files.flush();
await settle();
check("a shrink puts the block it cut", putsSince(mark).sort(), ["block 1", "record"]);
check("a shrink deletes the blocks past it", blocksStored(KEY, REL), [0, 1]);

// Loaded again: the same bytes.
page = await load(KEY);
check("blocks read back as the file", same(page.read(DB), expected), true);

// A file kept whole (before blocks): read as it was, into blocks at its next write.
const OLD = "blocks_old", OLDREL = "Documents/old.bin";
const oldData = pattern(150 * 1024, 3);
fake.records.set(keyText([OLD, "Documents"]), { key: [OLD, "Documents"], value: { type: "directory" } });
fake.records.set(keyText([OLD, OLDREL]), { key: [OLD, OLDREL], value: { type: "file", data: oldData, mtime: 0 } });
page = await load(OLD);
check("a whole record reads", same(page.read("home/app/" + OLDREL), oldData), true);
fd = page.open("home/app/" + OLDREL);
page.write(fd, 10, Uint8Array.of(1, 2, 3));
oldData.set([1, 2, 3], 10);
await page.files.flush();
await settle();
check("its next write puts every block", blocksStored(OLD, OLDREL), [0, 1, 2]);
check("its record keeps no bytes now", "data" in fake.records.get(keyText([OLD, OLDREL])).value, false);
page = await load(OLD);
check("and reads back the same", same(page.read("home/app/" + OLDREL), oldData), true);

// A page that goes before its write reaches IndexedDB: its journal has the
// changed blocks, laid over what IndexedDB had at the next load.
page = await load(KEY);
fd = page.open(DB);
const late = pattern(2048, 11);
page.write(fd, 70 * 1024, late);
expected.set(late, 70 * 1024);
fake.frozen = true;
pagehide();
const journal = JSON.parse(localStorage.getItem(`isomer-files:${KEY}`));
check("the journal holds the changed block", Object.keys(journal[REL].blocks), ["1"]);
await settle();
fake.frozen = false;
page = await load(KEY);
check("the journal is laid over IndexedDB", same(page.read(DB), expected), true);
await settle(); // its replay, written on at once
check("then written to IndexedDB, the journal cleared", localStorage.getItem(`isomer-files:${KEY}`), null);
page = await load(KEY);
check("and kept", same(page.read(DB), expected), true);

// A journal written while a page stays (hidden, then shown again) is never
// older than IndexedDB: a later write that completes rewrites or clears it.
fd = page.open(DB);
page.write(fd, 0, pattern(10, 21));
expected.set(pattern(10, 21), 0);
pagehide(); // journal: block 0 as it is now
page.write(fd, 0, pattern(10, 22));
expected.set(pattern(10, 22), 0);
await page.files.flush();
await settle();
check("a completed write leaves no older journal", localStorage.getItem(`isomer-files:${KEY}`), null);
page = await load(KEY);
check("the newer bytes are what load", same(page.read(DB), expected), true);

if (failures) {
  console.log(`${failures} failed`);
  process.exit(1);
}
console.log("all passed");
// Done (the open timeout file_system.js sets would keep Node waiting).
process.exit(0);
