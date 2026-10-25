// Exercises the web Playground's WASI shim (toolchain/driver.js) under Node
// with a small C program compiled for wasm32-wasi: reads a file from a
// preopen, writes another, lists a directory, prints to stdout/stderr, and
// exits with a code. Usage: node test_wasi_shim.mjs <program.wasm>
import { readFileSync } from "node:fs";
import { MemFS, WASI } from "../../web/playground_web_application/toolchain_driver.js";

const wasm = readFileSync(process.argv[2]);
const fs = new MemFS();
fs.put("/work/input.txt", new TextEncoder().encode("hello from memfs\n"));
fs.put("/toolchain/lib/a.a", new Uint8Array([1, 2, 3]));
fs.put("/toolchain/lib/b.a", new Uint8Array([4]));
const lines = [];
const wasi = new WASI({ fs, args: ["prog", "/work/input.txt", "/work/output.txt", "/toolchain/lib"], onOutput: (fd, line) => lines.push(`${fd}: ${line}`) });
const code = wasi.run(await WebAssembly.compile(wasm));
console.log("exit", code);
for (const l of lines) console.log(l);
console.log("output.txt =", JSON.stringify(new TextDecoder().decode(fs.get("/work/output.txt") || new Uint8Array())));
const ok = code === 7 && lines.some((l) => l.includes("read: hello from memfs")) && lines.some((l) => l.includes("a.a")) && lines.some((l) => l.includes("b.a"))
  && new TextDecoder().decode(fs.get("/work/output.txt")).startsWith("copied: hello from memfs");
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
