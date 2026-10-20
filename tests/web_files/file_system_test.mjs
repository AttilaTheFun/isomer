// The web's app files (wasm/libraries/swift_ui/runtime/file_system.js) at the
// WASI layer, in Node, with no browser: the calls a guest's Foundation makes
// (wasi-libc's open, read, write, seek, stat, mkdir, rmdir, unlink, rename,
// readdir and the preopen and environment it starts from), against a memory
// of its own. Node has no IndexedDB, so the files live in memory (the one
// warning is expected); persistence is checked in a browser by
// tools/testing/run_files_check.js.

import { openAppFiles } from "./file_system.js";
import { storeFiles } from "./imported_files.js";

const memory = new WebAssembly.Memory({ initial: 2 });
const view = () => new DataView(memory.buffer);
const bytes = () => new Uint8Array(memory.buffer);
const encoder = new TextEncoder();
const decoder = new TextDecoder();

const stdout = [];
const files = await openAppFiles("file_system_test");
const wasi = files.wasi(() => memory, { fd_write: (fd) => { stdout.push(fd); return 0; } }, { environment: { EXTRA: "1" } });

let failures = 0;
function check(name, found, expected) {
  const ok = JSON.stringify(found) === JSON.stringify(expected);
  if (!ok) failures += 1;
  console.log(ok ? `ok ${name}` : `FAIL ${name}: ${JSON.stringify(found)}, expected ${JSON.stringify(expected)}`);
}

// Scratch addresses in the guest's memory.
const PATH = 1024, PATH2 = 1536, IOVEC = 3000, COUNT = 3100, RESULT = 2000, STAT = 5000, DIRENTS = 6000, DATA = 8192;
// Errnos come back negative from these helpers.
const RIGHT_READ = 1n << 1n, RIGHT_WRITE = 1n << 6n;
const O_CREAT = 1, O_DIRECTORY = 2, O_EXCL = 4, O_TRUNC = 8, APPEND = 1;
const put = (text, at) => {
  const encoded = encoder.encode(text);
  bytes().set(encoded, at);
  return encoded.length;
};
const open = (path, oflags = 0, rights = RIGHT_READ, fdflags = 0) => {
  const error = wasi.path_open(3, 0, PATH, put(path, PATH), oflags, rights, 0n, fdflags, RESULT);
  return error ? -error : view().getUint32(RESULT, true);
};
const write = (fd, text) => {
  view().setUint32(IOVEC, DATA, true);
  view().setUint32(IOVEC + 4, put(text, DATA), true);
  const error = wasi.fd_write(fd, IOVEC, 1, COUNT);
  return error ? -error : view().getUint32(COUNT, true);
};
const read = (fd, length = 100) => {
  view().setUint32(IOVEC, DATA, true);
  view().setUint32(IOVEC + 4, length, true);
  const error = wasi.fd_read(fd, IOVEC, 1, COUNT);
  return error ? -error : decoder.decode(bytes().slice(DATA, DATA + view().getUint32(COUNT, true)));
};
const stat = (path) => {
  const error = wasi.path_filestat_get(3, 1, PATH, put(path, PATH), STAT);
  if (error) return -error;
  return { type: view().getUint8(STAT + 16), size: Number(view().getBigUint64(STAT + 32, true)) };
};
const onPath = (call, path) => wasi[call](3, PATH, put(path, PATH));
const rename = (from, to) => wasi.path_rename(3, PATH, put(from, PATH), 3, PATH2, put(to, PATH2));
// A directory's names, read through a buffer small enough that entries are
// cut off at its end, as wasi-libc's readdir copes with.
const list = (path) => {
  const fd = open(path, O_DIRECTORY);
  if (fd < 0) return fd;
  const names = [];
  let cookie = 0n;
  for (let reads = 0; reads < 100; reads++) {
    const error = wasi.fd_readdir(fd, DIRENTS, 64, cookie, COUNT);
    if (error) return -error;
    const used = view().getUint32(COUNT, true);
    let offset = 0;
    while (offset + 24 <= used) {
      const length = view().getUint32(DIRENTS + offset + 16, true);
      if (offset + 24 + length > used) break;
      names.push(decoder.decode(bytes().slice(DIRENTS + offset + 24, DIRENTS + offset + 24 + length)));
      cookie = view().getBigUint64(DIRENTS + offset, true);
      offset += 24 + length;
    }
    if (used < 64) break;
  }
  wasi.fd_close(fd);
  return names;
};

// The preopen and the environment.
check("preopen", wasi.fd_prestat_get(3, RESULT), 0);
check("no second preopen", wasi.fd_prestat_get(4, RESULT), 8);
wasi.fd_prestat_dir_name(3, PATH, 1);
check("preopen's name", decoder.decode(bytes().slice(PATH, PATH + 1)), "/");
wasi.environ_sizes_get(RESULT, RESULT + 4);
const size = view().getUint32(RESULT + 4, true);
wasi.environ_get(RESULT + 8, DATA);
check("environment", decoder.decode(bytes().slice(DATA, DATA + size)).split("\0").filter(Boolean), [
  "HOME=/home/app",
  "XDG_DATA_HOME=/home/app/Library/Application Support",
  "XDG_CACHE_HOME=/home/app/Library/Caches",
  "TMPDIR=/tmp",
  "EXTRA=1",
]);

// The container's layout.
check("home", list("home/app"), [".", "..", "Documents", "Library"]);
check("library", list("home/app/Library"), [".", "..", "Application Support", "Caches"]);

// A file written, read, appended to, truncated.
let fd = open("home/app/Documents/a.txt", O_CREAT | O_TRUNC, RIGHT_READ | RIGHT_WRITE);
check("create", fd > 3, true);
check("write", write(fd, "hello"), 5);
check("write on", write(fd, " world"), 6);
check("seek", wasi.fd_seek(fd, 0n, 0, RESULT), 0);
check("read back", read(fd), "hello world");
wasi.fd_close(fd);
check("stat", stat("home/app/Documents/a.txt"), { type: 4, size: 11 });
check("exclusive create", open("home/app/Documents/a.txt", O_CREAT | O_EXCL, RIGHT_WRITE), -20);
fd = open("home/app/Documents/a.txt");
check("write to a read-only descriptor", write(fd, "x"), -8);
wasi.fd_close(fd);
fd = open("home/app/Documents/a.txt", 0, RIGHT_WRITE, APPEND);
write(fd, "!");
wasi.fd_close(fd);
fd = open("home/app/Documents/a.txt");
check("append", read(fd), "hello world!");
wasi.fd_close(fd);
wasi.fd_close(open("home/app/Documents/a.txt", O_TRUNC, RIGHT_WRITE));
check("truncate", stat("home/app/Documents/a.txt").size, 0);

// Directories made, listed, renamed and removed.
check("mkdir", onPath("path_create_directory", "home/app/Documents/d"), 0);
check("mkdir again", onPath("path_create_directory", "home/app/Documents/d"), 20);
check("mkdir without a parent", onPath("path_create_directory", "home/app/Documents/x/y"), 44);
for (let i = 0; i < 12; i++) wasi.fd_close(open(`home/app/Documents/d/a-longish-file-name-${i}.txt`, O_CREAT, RIGHT_WRITE));
check("a long listing", list("home/app/Documents/d").length, 14);
check("rmdir with something in it", onPath("path_remove_directory", "home/app/Documents/d"), 55);
check("unlink a directory", onPath("path_unlink_file", "home/app/Documents/d"), 31);
check("rename into itself", rename("home/app/Documents/d", "home/app/Documents/d/e"), 28);
check("rename a directory", rename("home/app/Documents/d", "home/app/Documents/e"), 0);
check("what it holds moved", list("home/app/Documents/e").length, 14);
check("a directory over a file", rename("home/app/Documents/e", "home/app/Documents/a.txt"), 54);
check("..", stat("home/app/Documents/e/../a.txt").type, 4);
check("a file named as a directory", stat("home/app/Documents/a.txt/"), -54);
check(".. above the root", stat("../../home").type, 3);

// Outside the container nothing can be made; /tmp can.
check("a file at the root", open("x.txt", O_CREAT, RIGHT_WRITE), -2);
check("a directory at the root", onPath("path_create_directory", "etc"), 2);
check("a file in /tmp", open("tmp/t.txt", O_CREAT, RIGHT_WRITE) > 3, true);
check("what isn't there", stat("etc/xdg/user-dirs.defaults"), -44);

// Picked files: readable, not changeable.
const paths = await storeFiles([new File(["picked"], "p.txt")]);
check("picked file's path", paths, ["/tmp/iso-import/1/p.txt"]);
fd = open("tmp/iso-import/1/p.txt");
check("picked file read", read(fd), "picked");
wasi.fd_close(fd);
check("picked file written", open("tmp/iso-import/1/p.txt", 0, RIGHT_WRITE), -69);
check("picked file removed", onPath("path_unlink_file", "tmp/iso-import/1/p.txt"), 69);
check("imports moved", rename("tmp/iso-import", "tmp/elsewhere"), 69);

// What isn't a file of ours goes to the built-ins.
wasi.fd_write(1, IOVEC, 0, COUNT);
check("stdout passed on", stdout, [1]);

console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);
