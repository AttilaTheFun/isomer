// The app's disk on the web: the file system Isomer's Foundation
// (swift-foundation over WASI) reads and writes, one per app, laid out as an
// iOS app's container is, so `FileManager`, `Data(contentsOf:)` and
// `Data.write(to:)` find the directories they find on an iPhone:
//
//   /home/app                               HOME, NSHomeDirectory()
//   /home/app/Documents                     .documentDirectory
//   /home/app/Library/Application Support   .applicationSupportDirectory
//   /home/app/Library/Caches                .cachesDirectory
//   /tmp                                    the temporary directory
//   /tmp/iso-import                         picked and dropped files
//                                           (imported_files.js), read-only
//
// swift-foundation finds them on WASI through the environment the guest is
// given: HOME (there are no users to look up), XDG_DATA_HOME and
// XDG_CACHE_HOME (it would use ~/.local/share and ~/.cache without them);
// Documents is ~/Documents, and the temporary directory is /tmp/ whatever
// TMPDIR says. The whole tree is one directory, "/", preopened to the guest
// as fd 3; outside HOME and /tmp nothing can be made or changed (EACCES), as
// outside an app's container.
//
// What is under HOME persists: each file and directory is a record in the
// origin's IndexedDB database "isomer-files", keyed by [the app's key, its
// path under HOME], and a file's bytes are records of BLOCK bytes beside it,
// keyed by [the app's key, its path, the block's number]. They are read
// before the reactor starts and written behind the guest's changes
// (together, WRITE_DELAY_MS after the first of them, and at once when the
// page is hidden or left), only the records that changed: a database that
// rewrites one 4 KiB page puts one block, not the whole file. What a leaving
// page may not finish writing there goes to localStorage as well, for the
// next load to write on (writeJournal). A file kept whole in its own record,
// as before blocks, is read as it was and kept in blocks from its next write. /tmp lives in memory and goes with
// the page. Where IndexedDB can't be had (an opaque origin, a private
// window that refuses it) the app's files live in memory for the page's
// life, with one warning. The browser may still evict an origin's data
// under storage pressure, as it may any site's.

/** The app's home directory in the guest. */
export const HOME = "/home/app";

/** What the guest is told about the layout (environ_get). */
export const FILE_ENVIRONMENT = {
  HOME,
  XDG_DATA_HOME: `${HOME}/Library/Application Support`,
  XDG_CACHE_HOME: `${HOME}/Library/Caches`,
  // Not read by swift-foundation on WASI (its temporary directory is always
  // /tmp/), but true, for code that asks the environment.
  TMPDIR: "/tmp",
};

// The directories every app finds in its home, as in an iOS container.
const HOME_DIRECTORIES = ["Documents", "Library", "Library/Application Support", "Library/Caches"];

const DATABASE = "isomer-files";
const STORE = "files";
// How long the guest's first unwritten change waits for more before they
// are written together.
const WRITE_DELAY_MS = 300;
// The most file bytes a leaving page puts in its localStorage journal.
const JOURNAL_LIMIT = 1 << 20;
// A file's bytes are kept in IndexedDB in pieces of this size, each put
// again only when a write touched it.
const BLOCK = 1 << 16;

// wasi_snapshot_preview1's numbers.
const SUCCESS = 0, EACCES = 2, EBADF = 8, EEXIST = 20, EINVAL = 28, EISDIR = 31,
  ENOENT = 44, ENOTDIR = 54, ENOTEMPTY = 55, ENOTSUP = 58, EROFS = 69, ESPIPE = 70;
const DIRECTORY = 3, REGULAR_FILE = 4;
const O_CREAT = 1, O_DIRECTORY = 2, O_EXCL = 4, O_TRUNC = 8;
const FDFLAG_APPEND = 1;
const SET_ATIM = 1, SET_ATIM_NOW = 2, SET_MTIM = 4, SET_MTIM_NOW = 8;
const RIGHT_FD_READ = 1n << 1n, RIGHT_FD_WRITE = 1n << 6n;
const ALL_RIGHTS = 0xffffffffffffffffn;
const PREOPEN_FD = 3;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// --- The tree ---------------------------------------------------------------

let lastInode = 0n;
const now = () => BigInt(Date.now()) * 1000000n;

// A file or directory. `writeError` is why the guest can't change it or
// what is in it (EACCES outside its container, EROFS for imported files),
// or SUCCESS. A file's bytes are `data` up to `size` (the rest is spare
// capacity, kept zero).
function makeNode(type, writeError = SUCCESS) {
  const time = now();
  return {
    type, ino: ++lastInode, parent: null, name: "",
    entries: type === DIRECTORY ? new Map() : null,
    data: type === DIRECTORY ? null : new Uint8Array(0), size: 0,
    atime: time, mtime: time, ctime: time,
    writeError,
  };
}

function attach(directory, name, node) {
  node.parent = directory;
  node.name = name;
  directory.entries.set(name, node);
  directory.mtime = directory.ctime = now();
}

function detach(node) {
  const directory = node.parent;
  directory.entries.delete(node.name);
  directory.mtime = directory.ctime = now();
  node.parent = null;
}

// The directory `name` in `directory`, made if it isn't there.
function directoryIn(directory, name, writeError = SUCCESS) {
  let node = directory.entries.get(name);
  if (!node) {
    node = makeNode(DIRECTORY, writeError);
    attach(directory, name, node);
  }
  return node;
}

// Sets a file's size, growing its buffer by doubling (writes come in small
// pieces) and zeroing what a shrink gives up, so a later growth reads zeros.
function resize(node, size) {
  if (size > node.data.length) {
    const data = new Uint8Array(Math.max(size, node.data.length * 2));
    data.set(node.data.subarray(0, node.size));
    node.data = data;
  } else if (size < node.size) {
    node.data.fill(0, size, node.size);
  }
  node.size = size;
}

// Finds `path` (relative, as WASI's calls give it) from the directory
// `start`: { parent, name, node }, with no node when only the last name is
// missing, or an errno. ".." above the root stays at the root; a directory
// removed while open (no parent) has nothing above it.
function lookup(start, path) {
  const names = path.split("/").filter((name) => name && name !== ".");
  let directory = start;
  for (let i = 0; i < names.length - 1; i++) {
    const next = names[i] === ".." ? directory.parent : directory.entries.get(names[i]);
    if (!next) return ENOENT;
    if (next.type !== DIRECTORY) return ENOTDIR;
    directory = next;
  }
  const last = names[names.length - 1];
  let found;
  if (last === undefined) found = { parent: start.parent, name: start.name, node: start };
  else if (last === "..") found = directory.parent && { parent: directory.parent.parent, name: directory.parent.name, node: directory.parent };
  else found = { parent: directory, name: last, node: directory.entries.get(last) };
  if (!found || !found.parent) return ENOENT;
  // "name/" names a directory.
  if (path.endsWith("/") && found.node && found.node.type !== DIRECTORY) return ENOTDIR;
  return found;
}

// --- Imported files ---------------------------------------------------------

// What the person picked or dropped on this page, in every app's
// /tmp/iso-import (apps opened later get the ones before them too).
const imported = [];
const importDirectories = new Set();

function placeImported(directory, relative, data) {
  const [folder, name] = relative.split("/");
  const file = makeNode(REGULAR_FILE, EROFS);
  file.data = data;
  file.size = data.length;
  attach(directoryIn(directory, folder, EROFS), name, file);
}

/** Puts a picked or dropped file at /tmp/iso-import/<relative> ("<n>/<name>")
 *  in every app's tree. */
export function addImportedFile(relative, data) {
  imported.push([relative, data]);
  for (const directory of importDirectories) placeImported(directory, relative, data);
}

// --- Persistence ------------------------------------------------------------

let warned = false;
function warnOnce(message, error) {
  if (warned) return;
  warned = true;
  console.warn(`[files] ${message}`, error);
}

const requestDone = (request) => new Promise((resolve, reject) => {
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});

let databaseOpening = null;
function openDatabase() {
  databaseOpening ??= new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined" || !indexedDB) throw new Error("this page has no IndexedDB");
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => {
      const database = request.result;
      // Another page upgrading or deleting the database: let it.
      database.onversionchange = () => database.close();
      resolve(database);
    };
    request.onerror = () => reject(request.error);
    // Safari has been known to leave a first open unanswered.
    setTimeout(() => reject(new Error("IndexedDB did not open")), 10000);
  });
  return databaseOpening;
}

const toBase64 = (data) => {
  let text = "";
  for (let i = 0; i < data.length; i += 0x8000) text += String.fromCharCode.apply(null, data.subarray(i, i + 0x8000));
  return btoa(text);
};
const fromBase64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

// The record a node is kept as (its path under HOME is the key's second
// half): a file's size and time, its bytes being its blocks' records.
// Directories keep no time: theirs changes with every entry.
function recordOf(node) {
  if (node.type === DIRECTORY) return { type: "directory" };
  return { type: "file", size: node.size, blocks: true, mtime: Number(node.mtime / 1000000n) };
}

// Block `index` of a file's bytes (the last one may be short).
const blockOf = (node, index) => node.data.slice(index * BLOCK, Math.min(node.size, (index + 1) * BLOCK));
const blockCount = (node) => Math.ceil(node.size / BLOCK);

// A file's bytes from its record: its own `data` (kept whole, as before
// blocks), or its blocks ([number, bytes] pairs) laid out to its size.
function bytesOf(record, blocks) {
  if (!record.blocks) return record.data;
  const data = new Uint8Array(record.size);
  for (const [index, block] of blocks || []) {
    if (index * BLOCK < record.size) data.set(block.subarray(0, record.size - index * BLOCK), index * BLOCK);
  }
  return data;
}

// Puts a record read back at `path` under `home`, with the directories
// above it (they come first in key order, but needn't); a file's bytes are
// `data`. A record that contradicts the tree (a file where a directory is)
// is left out. Returns the file placed, if one was.
function place(home, path, record, data) {
  const names = path.split("/");
  let directory = home;
  for (const name of names.slice(0, -1)) {
    directory = directoryIn(directory, name);
    if (directory.type !== DIRECTORY) return;
  }
  const name = names[names.length - 1];
  if (record.type === "directory") {
    directoryIn(directory, name);
  } else if (!directory.entries.has(name)) {
    const file = makeNode(REGULAR_FILE);
    file.data = data;
    file.size = data.length;
    file.mtime = file.ctime = BigInt(record.mtime) * 1000000n;
    attach(directory, name, file);
    return file;
  }
  return null;
}

// --- An app's files ---------------------------------------------------------

/** The key an app's files are kept under on this origin: the page's
 *  `bundleIdentifier` when it gives one, else the reactor's URL without its
 *  query (the site's cache stamp), else the page's path. Two apps at
 *  different paths of one origin keep apart; apps served one after another
 *  at the same address (a development server's) share one home unless their
 *  pages name themselves. */
export function appFilesKey(bundleIdentifier, wasmURL) {
  if (bundleIdentifier) return bundleIdentifier;
  return new URL(wasmURL || location.pathname, location.href).pathname;
}

const opened = new Map(); // key -> Promise<AppFiles>

/** The app's files, read from IndexedDB the first time this page asks for
 *  `key` (a reactor started again, hot reloading, finds them as it left
 *  them). Never fails: without storage the files live in memory. */
export function openAppFiles(key) {
  if (!opened.has(key)) opened.set(key, createAppFiles(key));
  return opened.get(key);
}

async function createAppFiles(key) {
  const root = makeNode(DIRECTORY, EACCES);
  root.parent = root;
  const home = directoryIn(directoryIn(root, "home", EACCES), "app");
  for (const path of HOME_DIRECTORIES) path.split("/").reduce((directory, name) => directoryIn(directory, name), home);
  const tmp = directoryIn(root, "tmp");
  const importDirectory = directoryIn(tmp, "iso-import", EROFS);
  for (const [relative, data] of imported) placeImported(importDirectory, relative, data);
  importDirectories.add(importDirectory);

  // The node at `path` under HOME, if there is one.
  const atPath = (path) => {
    let node = home;
    for (const name of path.split("/")) {
      node = node.entries && node.entries.get(name);
      if (!node) return null;
    }
    return node;
  };
  // A node's path under HOME: null when it is elsewhere or no longer in
  // the tree, "" for HOME itself.
  const pathOf = (node) => {
    const names = [];
    for (let n = node; n !== home; n = n.parent) {
      if (!n.parent || n === root) return null;
      names.push(n.name);
    }
    return names.reverse().join("/");
  };

  // Files read from records that kept them whole (before blocks).
  const wholeFiles = new Set();
  let database = null;
  try {
    database = await openDatabase();
    const transaction = database.transaction(STORE, "readonly");
    const store = transaction.objectStore(STORE);
    // Every key of this app's: [key, path] sorts after [key] and before
    // [key, <an array>].
    const range = IDBKeyRange.bound([key], [key, []]);
    const [keys, records] = await Promise.all([requestDone(store.getAllKeys(range)), requestDone(store.getAll(range))]);
    // A file's blocks ([key, path, number]) come right after its record.
    const blocks = new Map();
    keys.forEach(([, path, index], i) => {
      if (index === undefined) return;
      if (!blocks.has(path)) blocks.set(path, []);
      blocks.get(path).push([index, records[i]]);
    });
    keys.forEach(([, path, index], i) => {
      if (index !== undefined) return;
      const record = records[i];
      const file = place(home, path, record, record.type === "file" ? bytesOf(record, blocks.get(path)) : null);
      // Kept whole before blocks: all of it goes into blocks at its next write.
      if (file && !record.blocks) wholeFiles.add(file);
    });
  } catch (error) {
    database = null;
    warnOnce("IndexedDB is unavailable: the app's files are kept in memory and go with the page.", error);
  }

  // Paths under HOME changed since the last write, each with the numbers of
  // its blocks that changed (ALL: every one); at the write, each path is put
  // as what is there now (its record, and those of its blocks), or deleted
  // when nothing is. `writing` holds the same for each write not yet
  // complete.
  const dirty = new Map();
  const writing = new Set();
  let timer = 0;
  const ALL = "all";
  function markDirty(path, blocks) {
    const known = dirty.get(path);
    if (known === ALL) return;
    if (blocks === ALL) return void dirty.set(path, ALL);
    const set = known || new Set();
    for (const index of blocks) set.add(index);
    dirty.set(path, set);
  }
  // Every block of a file's from `index` on.
  const blocksFrom = (path, index) => IDBKeyRange.bound([key, path, index], [key, path, Infinity]);
  function flush() {
    clearTimeout(timer);
    timer = 0;
    if (!database || !dirty.size) return Promise.resolve();
    const batch = new Map(dirty);
    dirty.clear();
    const failed = (error) => {
      writing.delete(batch);
      // Kept for the next write (a full disk may have room by then), whole:
      // what reached IndexedDB of this one isn't known.
      for (const path of batch.keys()) markDirty(path, ALL);
      warnOnce("could not write the app's files to IndexedDB.", error);
    };
    try {
      const transaction = database.transaction(STORE, "readwrite");
      const store = transaction.objectStore(STORE);
      for (const [path, blocks] of batch) {
        const node = atPath(path);
        if (!node) {
          store.delete([key, path]);
          store.delete(blocksFrom(path, 0));
          continue;
        }
        store.put(recordOf(node), [key, path]);
        if (node.type !== REGULAR_FILE) {
          store.delete(blocksFrom(path, 0));
          continue;
        }
        const count = blockCount(node);
        const whole = blocks === ALL || wholeFiles.has(node);
        wholeFiles.delete(node);
        for (let index = 0; index < count; index++) {
          if (whole || blocks.has(index)) store.put(blockOf(node, index), [key, path, index]);
        }
        // What a shrink gave up (and a file kept whole before blocks).
        store.delete(blocksFrom(path, count));
      }
      writing.add(batch);
      // Sent now: the page may be going.
      if (transaction.commit) transaction.commit();
      return new Promise((resolve) => {
        transaction.oncomplete = () => {
          writing.delete(batch);
          // Everything is in IndexedDB: a journal has nothing left to say.
          // Else one written before this write would hold blocks older than
          // the ones it put, which the next load would lay over them: it is
          // written again from what is still to come.
          if (!dirty.size && !writing.size) clearJournal();
          else if (journaled) writeJournal();
          resolve();
        };
        transaction.onerror = transaction.onabort = () => {
          failed(transaction.error);
          resolve();
        };
      });
    } catch (error) {
      failed(error);
      return Promise.resolve();
    }
  }

  // A leaving page's last write to IndexedDB may be cut off: the browser
  // aborts what a document hasn't finished when it goes, and a write begun
  // in `pagehide` doesn't always finish first. So whenever the page is
  // hidden or left, what isn't yet known to be in IndexedDB is also put in
  // localStorage (which a leaving page writes at once), as a journal the
  // next load plays over what IndexedDB had and writes on: the blocks that
  // changed, with their file's size. Up to JOURNAL_LIMIT bytes of blocks;
  // beyond, IndexedDB alone.
  const journalKey = `${DATABASE}:${key}`;
  let journaled = false;
  function writeJournal() {
    const pending = new Map();
    const add = (path, blocks) => {
      const known = pending.get(path);
      if (known === ALL || blocks === ALL) return void pending.set(path, ALL);
      pending.set(path, new Set([...(known || []), ...blocks]));
    };
    for (const [path, blocks] of dirty) add(path, blocks);
    for (const batch of writing) for (const [path, blocks] of batch) add(path, blocks);
    if (!pending.size) return;
    const journal = {};
    let size = 0;
    for (const [path, blocks] of pending) {
      const node = atPath(path);
      if (node && node.type === REGULAR_FILE) {
        const count = blockCount(node);
        const whole = blocks === ALL || wholeFiles.has(node);
        const entry = { type: "file", size: node.size, mtime: Number(node.mtime / 1000000n), blocks: {} };
        for (let index = 0; index < count; index++) {
          if (!whole && !blocks.has(index)) continue;
          const block = blockOf(node, index);
          size += block.length;
          if (size > JOURNAL_LIMIT) return clearJournal();
          entry.blocks[index] = toBase64(block);
        }
        journal[path] = entry;
      } else {
        journal[path] = node ? { type: "directory" } : null;
      }
    }
    try {
      localStorage.setItem(journalKey, JSON.stringify(journal));
      journaled = true;
    } catch (_) {
      clearJournal();
    }
  }
  function clearJournal() {
    journaled = false;
    try { localStorage.removeItem(journalKey); } catch (_) { /* no storage */ }
  }
  function leave() {
    writeJournal();
    flush();
  }
  if (database) {
    // The last page's journal, over what IndexedDB had; written on at once.
    let journal = null;
    try { journal = JSON.parse(localStorage.getItem(journalKey) || "null"); } catch (_) { /* none */ }
    journaled = journal !== null;
    for (const [path, record] of Object.entries(journal || {})) {
      const found = atPath(path);
      if (record && record.type === "file" && record.blocks && found && found.type === REGULAR_FILE) {
        // The blocks that changed, over the file IndexedDB had.
        resize(found, record.size);
        for (const [index, text] of Object.entries(record.blocks)) found.data.set(fromBase64(text), Number(index) * BLOCK);
        found.mtime = found.ctime = BigInt(record.mtime) * 1000000n;
        markDirty(path, Object.keys(record.blocks).map(Number));
        continue;
      }
      // A directory stays as it is, with what is in it.
      const kept = found && record && record.type === "directory" && found.type === DIRECTORY;
      if (found && !kept) {
        markTree(found);
        detach(found);
      }
      if (record && !kept) {
        const data = record.type !== "file" ? null
          : record.blocks ? bytesOf({ ...record, blocks: true }, Object.entries(record.blocks).map(([index, text]) => [Number(index), fromBase64(text)]))
          : fromBase64(record.data);
        place(home, path, record, data);
      }
      markDirty(path, ALL);
    }
    if (dirty.size) timer = setTimeout(flush, 0);
    if (typeof window !== "undefined") {
      window.addEventListener("pagehide", leave);
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "hidden") leave();
      });
    }
  }

  // `node` and everything in it, as changed (all of each file's blocks).
  function markTree(node) {
    const path = pathOf(node);
    if (path) markDirty(path, ALL);
    if (node.entries) for (const child of node.entries.values()) markTree(child);
  }

  const files = {
    key, root, home,
    /** Writes what changed now (it would be written a moment later). */
    flush,
    // `node`'s content, or its being there, changed: its bytes from `from`
    // to `to` when given (a write, a resize), else only what the node's
    // record says (its size, its time, its being there).
    changed(node, from, to) {
      if (!database) return;
      const path = pathOf(node);
      if (!path) return;
      const blocks = [];
      if (from !== undefined && to > from) {
        for (let index = Math.floor(from / BLOCK); index * BLOCK < to; index++) blocks.push(index);
      }
      markDirty(path, blocks);
      timer ||= setTimeout(flush, WRITE_DELAY_MS);
    },
    // `node` and everything in it (a directory moving).
    changedTree(node) {
      if (!database) return;
      markTree(node);
      timer ||= setTimeout(flush, WRITE_DELAY_MS);
    },
    /** WASI's file and environment calls over this tree, for one instance
     *  (each has its own descriptors): swift_ffi's `wasi` overrides, given
     *  the memory accessor and the built-ins, which keep stdin, stdout and
     *  stderr. `environment` adds variables to FILE_ENVIRONMENT. */
    wasi(getMemory, builtins = {}, { environment = {} } = {}) {
      return fileSystemWasi(files, getMemory, builtins, { ...FILE_ENVIRONMENT, ...environment });
    },
  };
  return files;
}

// --- WASI -------------------------------------------------------------------

function fileSystemWasi(files, getMemory, builtins, environment) {
  const view = () => new DataView(getMemory().buffer);
  const bytes = () => new Uint8Array(getMemory().buffer);
  const textAt = (ptr, len) => decoder.decode(bytes().slice(ptr, ptr + len));
  // fd -> { node, rights, flags, position, listing }
  const descriptors = new Map([[PREOPEN_FD, { node: files.root, rights: ALL_RIGHTS, flags: 0, position: 0, listing: null }]]);
  let nextFD = PREOPEN_FD + 1;
  // What isn't a file of ours (stdin, stdout, stderr) goes to the built-ins.
  const passOn = (name, args) => (builtins[name] ? builtins[name](...args) : EBADF);
  const directoryAt = (fd) => {
    const entry = descriptors.get(fd);
    if (!entry) return EBADF;
    return entry.node.type === DIRECTORY ? entry.node : ENOTDIR;
  };
  const find = (fd, ptr, len) => {
    const directory = directoryAt(fd);
    return typeof directory === "number" ? directory : lookup(directory, textAt(ptr, len));
  };

  const writeFilestat = (ptr, node) => {
    const v = view();
    v.setBigUint64(ptr, 1n, true); // dev: one volume, so a rename never crosses devices
    v.setBigUint64(ptr + 8, node.ino, true);
    v.setBigUint64(ptr + 16, 0n, true);
    v.setUint8(ptr + 16, node.type);
    // One link, directories included: fts (FileManager's removal) counts a
    // directory's subdirectories by its links and would take the rest for
    // files once that count ran out.
    v.setBigUint64(ptr + 24, 1n, true);
    v.setBigUint64(ptr + 32, BigInt(node.type === DIRECTORY ? 0 : node.size), true);
    v.setBigUint64(ptr + 40, node.atime, true);
    v.setBigUint64(ptr + 48, node.mtime, true);
    v.setBigUint64(ptr + 56, node.ctime, true);
  };
  const setTimes = (node, atim, mtim, fstflags) => {
    if (fstflags & SET_ATIM) node.atime = BigInt(atim);
    if (fstflags & SET_ATIM_NOW) node.atime = now();
    if (fstflags & SET_MTIM) node.mtime = BigInt(mtim);
    if (fstflags & SET_MTIM_NOW) node.mtime = now();
    node.ctime = now();
    files.changed(node);
    return SUCCESS;
  };
  // Each (pointer, length) of an iovec array.
  const iovecs = (iovs, count) => {
    const v = view();
    const list = [];
    for (let i = 0; i < count; i++) list.push([v.getUint32(iovs + i * 8, true), v.getUint32(iovs + i * 8 + 4, true)]);
    return list;
  };
  const readAt = (node, position, iovs, count) => {
    let total = 0;
    for (const [ptr, len] of iovecs(iovs, count)) {
      const chunk = node.data.subarray(Math.min(position, node.size), Math.min(position + len, node.size));
      bytes().set(chunk, ptr);
      position += chunk.length;
      total += chunk.length;
      if (chunk.length < len) break;
    }
    return total;
  };
  const writeAt = (node, position, iovs, count) => {
    const start = position;
    let total = 0;
    for (const [ptr, len] of iovecs(iovs, count)) {
      if (position + len > node.size) resize(node, position + len);
      node.data.set(bytes().subarray(ptr, ptr + len), position);
      position += len;
      total += len;
    }
    if (total) {
      node.mtime = node.ctime = now();
      files.changed(node, start, position);
    }
    return total;
  };
  // The open file `fd` with `right` (reading or writing): its entry, an
  // errno, or null when the descriptor isn't one of ours.
  const openFile = (fd, right) => {
    const entry = descriptors.get(fd);
    if (!entry) return null;
    if (entry.node.type === DIRECTORY) return EISDIR;
    return entry.rights & right ? entry : EBADF;
  };
  const environ = Object.entries(environment).map(([name, value]) => encoder.encode(`${name}=${value}\0`));

  return {
    environ_sizes_get: (countPtr, sizePtr) => {
      view().setUint32(countPtr, environ.length, true);
      view().setUint32(sizePtr, environ.reduce((sum, entry) => sum + entry.length, 0), true);
      return SUCCESS;
    },
    environ_get: (environPtr, bufferPtr) => {
      let offset = bufferPtr;
      environ.forEach((entry, index) => {
        view().setUint32(environPtr + index * 4, offset, true);
        bytes().set(entry, offset);
        offset += entry.length;
      });
      return SUCCESS;
    },

    fd_prestat_get: (fd, ptr) => {
      if (fd !== PREOPEN_FD) return EBADF;
      view().setUint32(ptr, 0, true); // a directory
      view().setUint32(ptr + 4, 1, true); // "/"
      return SUCCESS;
    },
    fd_prestat_dir_name: (fd, ptr, len) => {
      if (fd !== PREOPEN_FD) return EBADF;
      bytes().set(encoder.encode("/").subarray(0, len), ptr);
      return SUCCESS;
    },

    path_open: (fd, _lookupFlags, pathPtr, pathLen, oflags, rightsBase, _rightsInheriting, fdflags, fdPtr) => {
      const found = find(fd, pathPtr, pathLen);
      if (typeof found === "number") return found;
      let { parent, name, node } = found;
      const rights = BigInt(rightsBase);
      const writing = (rights & RIGHT_FD_WRITE) !== 0n || (oflags & O_TRUNC) !== 0;
      if (!node) {
        if (!(oflags & O_CREAT) || (oflags & O_DIRECTORY)) return ENOENT;
        if (parent.writeError) return parent.writeError;
        node = makeNode(REGULAR_FILE);
        attach(parent, name, node);
        files.changed(node);
      } else {
        if ((oflags & O_CREAT) && (oflags & O_EXCL)) return EEXIST;
        if (node.type === DIRECTORY) {
          if (writing) return EISDIR;
        } else if (oflags & O_DIRECTORY) {
          return ENOTDIR;
        }
        if (writing && node.writeError) return node.writeError;
        if ((oflags & O_TRUNC) && node.size) {
          resize(node, 0);
          node.mtime = node.ctime = now();
          files.changed(node);
        }
      }
      const opened = nextFD++;
      descriptors.set(opened, { node, rights, flags: fdflags, position: 0, listing: null });
      view().setUint32(fdPtr, opened, true);
      return SUCCESS;
    },
    fd_close: (fd) => {
      if (!descriptors.has(fd)) return passOn("fd_close", [fd]);
      if (fd !== PREOPEN_FD) descriptors.delete(fd);
      return SUCCESS;
    },
    fd_renumber: (from, to) => {
      const entry = descriptors.get(from);
      if (!entry || from === PREOPEN_FD || to === PREOPEN_FD) return EBADF;
      descriptors.delete(from);
      descriptors.set(to, entry);
      return SUCCESS;
    },
    fd_fdstat_get: (fd, ptr) => {
      const entry = descriptors.get(fd);
      if (!entry) return passOn("fd_fdstat_get", [fd, ptr]);
      const v = view();
      v.setBigUint64(ptr, 0n, true);
      v.setUint8(ptr, entry.node.type);
      v.setUint16(ptr + 2, entry.flags, true);
      const directory = entry.node.type === DIRECTORY;
      v.setBigUint64(ptr + 8, directory ? ALL_RIGHTS : entry.rights, true);
      v.setBigUint64(ptr + 16, directory ? ALL_RIGHTS : 0n, true);
      return SUCCESS;
    },
    fd_fdstat_set_flags: (fd, flags) => {
      const entry = descriptors.get(fd);
      if (!entry) return passOn("fd_fdstat_set_flags", [fd, flags]);
      entry.flags = flags;
      return SUCCESS;
    },
    fd_filestat_get: (fd, ptr) => {
      const entry = descriptors.get(fd);
      if (!entry) return passOn("fd_filestat_get", [fd, ptr]);
      writeFilestat(ptr, entry.node);
      return SUCCESS;
    },
    fd_filestat_set_size: (fd, size) => {
      const entry = openFile(fd, RIGHT_FD_WRITE);
      if (entry === null) return EBADF;
      if (typeof entry === "number") return entry === EISDIR ? EINVAL : entry;
      const before = entry.node.size;
      resize(entry.node, Number(size));
      entry.node.mtime = entry.node.ctime = now();
      // What grew, as zeros, or the last block a shrink cut short.
      files.changed(entry.node, Math.min(before, entry.node.size), Math.max(before, entry.node.size));
      return SUCCESS;
    },
    fd_filestat_set_times: (fd, atim, mtim, fstflags) => {
      const entry = descriptors.get(fd);
      if (!entry) return EBADF;
      if (entry.node.writeError) return entry.node.writeError;
      return setTimes(entry.node, atim, mtim, fstflags);
    },
    fd_read: (fd, iovs, count, nreadPtr) => {
      const entry = openFile(fd, RIGHT_FD_READ);
      if (entry === null) return passOn("fd_read", [fd, iovs, count, nreadPtr]);
      if (typeof entry === "number") return entry;
      const total = readAt(entry.node, entry.position, iovs, count);
      entry.position += total;
      view().setUint32(nreadPtr, total, true);
      return SUCCESS;
    },
    fd_pread: (fd, iovs, count, offset, nreadPtr) => {
      const entry = openFile(fd, RIGHT_FD_READ);
      if (entry === null) return passOn("fd_pread", [fd, iovs, count, offset, nreadPtr]);
      if (typeof entry === "number") return entry;
      view().setUint32(nreadPtr, readAt(entry.node, Number(offset), iovs, count), true);
      return SUCCESS;
    },
    fd_write: (fd, iovs, count, nwrittenPtr) => {
      const entry = openFile(fd, RIGHT_FD_WRITE);
      if (entry === null) return passOn("fd_write", [fd, iovs, count, nwrittenPtr]);
      if (typeof entry === "number") return entry;
      if (entry.flags & FDFLAG_APPEND) entry.position = entry.node.size;
      const total = writeAt(entry.node, entry.position, iovs, count);
      entry.position += total;
      view().setUint32(nwrittenPtr, total, true);
      return SUCCESS;
    },
    fd_pwrite: (fd, iovs, count, offset, nwrittenPtr) => {
      const entry = openFile(fd, RIGHT_FD_WRITE);
      if (entry === null) return passOn("fd_pwrite", [fd, iovs, count, offset, nwrittenPtr]);
      if (typeof entry === "number") return entry;
      view().setUint32(nwrittenPtr, writeAt(entry.node, Number(offset), iovs, count), true);
      return SUCCESS;
    },
    fd_seek: (fd, offset, whence, newOffsetPtr) => {
      const entry = descriptors.get(fd);
      if (!entry) return passOn("fd_seek", [fd, offset, whence, newOffsetPtr]);
      if (entry.node.type === DIRECTORY) return ESPIPE;
      const base = whence === 0 ? 0 : whence === 1 ? entry.position : entry.node.size;
      const position = base + Number(offset);
      if (position < 0 || whence > 2) return EINVAL;
      entry.position = position;
      view().setBigUint64(newOffsetPtr, BigInt(position), true);
      return SUCCESS;
    },
    fd_tell: (fd, offsetPtr) => {
      const entry = descriptors.get(fd);
      if (!entry) return passOn("fd_tell", [fd, offsetPtr]);
      view().setBigUint64(offsetPtr, BigInt(entry.position), true);
      return SUCCESS;
    },
    // Written behind on their own; a sync has nothing to wait for.
    fd_sync: (fd) => (descriptors.has(fd) ? SUCCESS : passOn("fd_sync", [fd])),
    fd_datasync: (fd) => (descriptors.has(fd) ? SUCCESS : passOn("fd_datasync", [fd])),
    fd_advise: (fd) => (descriptors.has(fd) ? SUCCESS : EBADF),
    fd_allocate: (fd, offset, len) => {
      const entry = openFile(fd, RIGHT_FD_WRITE);
      if (entry === null) return EBADF;
      if (typeof entry === "number") return entry;
      const size = Number(offset) + Number(len);
      if (size > entry.node.size) {
        const before = entry.node.size;
        resize(entry.node, size);
        files.changed(entry.node, before, size);
      }
      return SUCCESS;
    },
    // Entries from `cookie` on, each a 24-byte dirent and its name; the last
    // one cut off where the buffer ends, which tells wasi-libc to ask again
    // with a bigger one. The listing is taken when a read starts from the
    // top, so entries removed meanwhile (fts removing as it goes) don't
    // shift the cookies.
    fd_readdir: (fd, buffer, bufferLen, cookie, usedPtr) => {
      const entry = descriptors.get(fd);
      if (!entry) return EBADF;
      const directory = entry.node;
      if (directory.type !== DIRECTORY) return ENOTDIR;
      if (cookie === 0n || !entry.listing) {
        const names = [...directory.entries.keys()].sort();
        // (A directory removed while open has no parent: ".." is itself.)
        const parent = directory.parent || directory;
        entry.listing = [[".", directory], ["..", parent], ...names.map((name) => [name, directory.entries.get(name)])];
      }
      let used = 0;
      for (let index = Number(cookie); index < entry.listing.length && used < bufferLen; index++) {
        const [name, node] = entry.listing[index];
        const nameBytes = encoder.encode(name);
        const dirent = new Uint8Array(24 + nameBytes.length);
        const v = new DataView(dirent.buffer);
        v.setBigUint64(0, BigInt(index + 1), true); // the next entry's cookie
        v.setBigUint64(8, node.ino, true); // never 0: FileManager skips those
        v.setUint32(16, nameBytes.length, true);
        v.setUint8(20, node.type);
        dirent.set(nameBytes, 24);
        const take = Math.min(dirent.length, bufferLen - used);
        bytes().set(dirent.subarray(0, take), buffer + used);
        used += take;
      }
      view().setUint32(usedPtr, used, true);
      return SUCCESS;
    },

    path_filestat_get: (fd, _lookupFlags, pathPtr, pathLen, ptr) => {
      const found = find(fd, pathPtr, pathLen);
      if (typeof found === "number") return found;
      if (!found.node) return ENOENT;
      writeFilestat(ptr, found.node);
      return SUCCESS;
    },
    path_filestat_set_times: (fd, _lookupFlags, pathPtr, pathLen, atim, mtim, fstflags) => {
      const found = find(fd, pathPtr, pathLen);
      if (typeof found === "number") return found;
      if (!found.node) return ENOENT;
      if (found.node.writeError) return found.node.writeError;
      return setTimes(found.node, atim, mtim, fstflags);
    },
    path_create_directory: (fd, pathPtr, pathLen) => {
      const found = find(fd, pathPtr, pathLen);
      if (typeof found === "number") return found;
      if (found.node) return EEXIST;
      if (found.parent.writeError) return found.parent.writeError;
      const directory = makeNode(DIRECTORY);
      attach(found.parent, found.name, directory);
      files.changed(directory);
      return SUCCESS;
    },
    path_remove_directory: (fd, pathPtr, pathLen) => {
      const found = find(fd, pathPtr, pathLen);
      if (typeof found === "number") return found;
      const { parent, node } = found;
      if (!node) return ENOENT;
      if (node.type !== DIRECTORY) return ENOTDIR;
      if (node === files.root) return EACCES;
      if (node.entries.size) return ENOTEMPTY;
      if (parent.writeError || node.writeError) return parent.writeError || node.writeError;
      files.changed(node);
      detach(node);
      return SUCCESS;
    },
    path_unlink_file: (fd, pathPtr, pathLen) => {
      const found = find(fd, pathPtr, pathLen);
      if (typeof found === "number") return found;
      const { parent, node } = found;
      if (!node) return ENOENT;
      if (node.type === DIRECTORY) return EISDIR;
      if (parent.writeError || node.writeError) return parent.writeError || node.writeError;
      files.changed(node);
      detach(node);
      return SUCCESS;
    },
    path_rename: (fd, oldPtr, oldLen, newFD, newPtr, newLen) => {
      const from = find(fd, oldPtr, oldLen);
      if (typeof from === "number") return from;
      const to = find(newFD, newPtr, newLen);
      if (typeof to === "number") return to;
      const node = from.node;
      if (!node) return ENOENT;
      if (node === files.root) return EACCES;
      if (from.parent.writeError || node.writeError) return from.parent.writeError || node.writeError;
      if (to.parent.writeError) return to.parent.writeError;
      if (to.node === node) return SUCCESS;
      // A directory can't go inside itself.
      for (let directory = to.parent; ; directory = directory.parent) {
        if (directory === node) return EINVAL;
        if (directory === files.root) break;
      }
      if (to.node) {
        if (to.node.writeError) return to.node.writeError;
        if (node.type === DIRECTORY) {
          if (to.node.type !== DIRECTORY) return ENOTDIR;
          if (to.node.entries.size) return ENOTEMPTY;
        } else if (to.node.type === DIRECTORY) {
          return EISDIR;
        }
        detach(to.node);
      }
      files.changedTree(node); // where it was
      detach(node);
      attach(to.parent, to.name, node);
      node.ctime = now();
      files.changedTree(node); // where it is
      return SUCCESS;
    },
    // No links of either kind.
    path_link: () => ENOTSUP,
    path_symlink: () => ENOTSUP,
    path_readlink: (fd, pathPtr, pathLen) => {
      const found = find(fd, pathPtr, pathLen);
      if (typeof found === "number") return found;
      return found.node ? EINVAL : ENOENT;
    },
  };
}
